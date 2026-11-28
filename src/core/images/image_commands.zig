const std = @import("std");
const agents = @import("../agents/agents.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const clipboard_read = @import("clipboard_read.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("image_attachments.zig");
const types = @import("../shared/types.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const render_request = @import("../../ui/render_request.zig");
const composer_insertion = @import("../input/composer_insertion.zig");
const composer_stash = @import("../input/composer_stash.zig");
const edit_contract = @import("../input/editor_state.zig");
const edit_history = @import("../input/edit_history.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const picker_state = @import("../input/picker_state.zig");
const registered_entities = @import("../input/registered_entities.zig");
const vertical_navigation = @import("../input/vertical_navigation.zig");

const InsertImageResult = enum { inserted, rejected, input_full };
const ImageSourceLifetime = enum { retained, temporary };

fn writeInputFullNotice(app: anytype) !void {
    try app.writeDomainNotice(.{
        .topic = "images",
        .tone = .neutral,
        .body = "input is full; image not attached",
    }, true);
}

pub fn Commands(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn attachPath(app: *App, path: []const u8) !void {
            const trimmed = std.mem.trim(u8, path, " \t");
            if (trimmed.len == 0) {
                try app.writeDomainNotice(.{ .topic = "", .tone = .@"error", .body = "usage: /image <path>" }, true);
                return;
            }

            const image = image_attachments.loadUserImageAttachment(
                app.alloc,
                app.workspace_root,
                trimmed,
            ) catch |err| {
                const line = switch (err) {
                    error.UnsupportedImageType => try app.alloc.dupe(u8, "unsupported image type"),
                    error.FileNotFound => try app.alloc.dupe(u8, "image file not found"),
                    error.ImageTooLarge => try app.alloc.dupe(u8, image_attachments.image_too_large_notice),
                    else => try app.alloc.print("failed to attach image: {s}", .{@errorName(err)}),
                };
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                return;
            };
            switch (try insertImageAtCursor(App, app, image, .retained)) {
                .inserted => {},
                .rejected => return,
                .input_full => {
                    try writeInputFullNotice(app);
                    return;
                },
            }

            const line = try app.alloc.print("attached image: {s}", .{std.Io.Dir.path.basename(image.path)});
            defer app.alloc.free(line);
            try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = line }, true);
        }

        pub fn managePending(app: *App, agent: *AppAgent, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (std.mem.eql(u8, trimmed, "clear")) {
                app.clearPendingImages(agent);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "cleared pending images" }, true);
                return;
            }

            if (agent.pending_images.items.len == 0) {
                try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "no pending images" }, true);
                return;
            }

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.print("{d} pending\n", .{agent.pending_images.items.len});
            for (agent.pending_images.items) |image| {
                try out.writer.print(" - {s} ({s})\n", .{ std.Io.Dir.path.basename(image.path), image.media_type });
            }
            const text = try out.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "images",
                .tone = .neutral,
                .body = std.mem.trimEnd(u8, text, "\n"),
            }, true);
        }

        /// `/paste` and Ctrl+V: starts reading the clipboard image and
        /// returns at once. `finishClipboard` attaches the image when the
        /// loop collects the read. Silent where fx cannot read clipboard
        /// images.
        pub fn attachClipboard(app: *App) !void {
            if (comptime !@hasField(App, "clipboard_read")) return;
            const started = app.clipboard_read.start(app.alloc, agents.screenAgentOf(app)) catch |err| {
                const line = try app.alloc.print("failed to paste clipboard image: {s}", .{@errorName(err)});
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                return;
            };
            switch (started) {
                .started => try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "reading clipboard" }, true),
                .busy => try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "already reading clipboard" }, true),
                .unsupported => {},
            }
        }

        /// Shows how a clipboard read ended, for the agent in context, which
        /// is the agent that asked. `draft` is that agent's stashed draft
        /// while it is hidden, or null when it is on screen and owns the
        /// composer. Takes the image out of `outcome`.
        pub fn finishClipboard(app: *App, outcome: *clipboard_read.Outcome, draft: ?*composer_stash.State) !void {
            switch (outcome.*) {
                .image => |*loaded| {
                    const result = if (draft) |stash| inserted: {
                        var composer: DraftComposer = .init(stash);
                        defer composer.deinit(app.alloc);
                        break :inserted try insertImageInto(App, app, &composer, loaded.takeAttachment(), .temporary);
                    } else try insertImageAtCursor(App, app, loaded.takeAttachment(), .temporary);
                    switch (result) {
                        .inserted => app.shell.render_requests.request(.footer),
                        .rejected => {},
                        .input_full => try writeInputFullNotice(app),
                    }
                },
                .no_image => try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "no image found on clipboard" }, true),
                .timed_out => try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = "clipboard read timed out" }, true),
                .failed => |err| {
                    const line = try app.alloc.print("failed to paste clipboard image: {s}", .{@errorName(err)});
                    defer app.alloc.free(line);
                    try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                },
            }
        }

        /// A clipboard read whose agent has closed: its image has nowhere to
        /// go, so it is dropped with a notice and a trace line.
        pub fn dropClipboard(app: *App, outcome: *const clipboard_read.Outcome) !void {
            debug_trace.logf("images", "event=clipboard_read_dropped reason=agent_closed outcome={s}", .{@tagName(outcome.*)});
            if (outcome.* != .image) return;
            try app.writeDomainNotice(.{
                .topic = "images",
                .tone = .neutral,
                .body = "clipboard image not attached: the agent that asked has closed",
            }, true);
        }

        fn insertImageAtCursor(
            comptime A: type,
            app: *A,
            image: types.ImageAttachment,
            source_lifetime: ImageSourceLifetime,
        ) !InsertImageResult {
            return insertImageInto(A, app, &app.input_runtime, image, source_lifetime);
        }

        /// Inserts `image`'s placeholder at `composer`'s cursor and attaches
        /// it to the agent in context: the live composer, or a hidden
        /// agent's `DraftComposer`.
        fn insertImageInto(
            comptime A: type,
            app: *A,
            composer: anytype,
            image: types.ImageAttachment,
            source_lifetime: ImageSourceLifetime,
        ) !InsertImageResult {
            var attached = image;
            var owns_attached = true;
            defer if (owns_attached) image_attachments.discardImageAttachment(app.alloc, attached);

            const id = app.peekNextImageId(agents.screenAgentOf(app));
            _ = try std.math.add(usize, id, 1);
            attached.id = id;

            var buf: [32]u8 = undefined;
            const placeholder = try image_attachments.formatImagePlaceholder(&buf, id);
            const max_input_len = if (comptime @hasDecl(A, "input_limits"))
                A.input_limits.composer_bytes
            else if (comptime @hasDecl(A, "input_byte_limit"))
                A.input_byte_limit
            else
                std.math.maxInt(usize);
            if (!composer.insertionState().canInsert(placeholder.len, max_input_len)) {
                return .input_full;
            }

            try composer.edit_state.input.ensureUnusedCapacity(
                app.alloc,
                placeholder.len,
            );
            try agents.screenAgentOf(app).pending_images.ensureUnusedCapacity(app.alloc, 1);
            if (comptime @hasField(@TypeOf(composer.*), "entities")) {
                try composer.entities.image_tokens.ensureUnusedCapacity(app.alloc, 1);
            }
            switch (try image_attachments.captureImageAttachmentForAdmission(A, app, &attached)) {
                .captured => {},
                .rejected => return .rejected,
            }
            if (source_lifetime == .temporary) {
                const snapshot_path = attached.snapshot_path orelse return error.MissingImageSnapshot;
                const display_path = try app.alloc.dupe(u8, snapshot_path);
                app.alloc.free(attached.path);
                attached.path = display_path;
            }

            const raw_start = composer.edit_state.cursor;
            composer.vertical_navigation.reset();
            composer.insertionState().insertSliceAssumeCapacity(
                app.alloc,
                placeholder,
            );
            if (comptime @hasField(@TypeOf(composer.*), "entities")) {
                composer.entities.registerImageTokenAssumeCapacity(.{
                    .id = id,
                    .span = .{
                        .raw_start = raw_start,
                        .raw_end = raw_start + placeholder.len,
                    },
                });
            }
            if (agents.screenAgentOf(app).pending_images.items.len > 0) {
                std.debug.assert(agents.screenAgentOf(app).pending_images.items[agents.screenAgentOf(app).pending_images.items.len - 1].id < attached.id);
            }
            agents.screenAgentOf(app).pending_images.appendAssumeCapacity(attached);
            const committed_id = app.nextImageId(agents.screenAgentOf(app));
            std.debug.assert(committed_id == id);
            if (comptime @hasDecl(@TypeOf(composer.*), "historyBoundary")) {
                composer.historyBoundary(app.alloc);
            }
            owns_attached = false;
            return .inserted;
        }
    };
}

/// A hidden agent's stashed draft, as a composer to insert into. The live
/// composer's picker belongs to the agent on screen, so insertion here
/// reconciles a scratch picker and leaves the visible one alone.
const DraftComposer = struct {
    edit_state: *edit_contract.State,
    entities: *registered_entities.State,
    edit_history: *edit_history.State,
    vertical_navigation: *vertical_navigation.State,
    picker: picker_state.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},

    fn init(draft: *composer_stash.State) DraftComposer {
        return .{
            .edit_state = &draft.edit,
            .entities = &draft.entities,
            .edit_history = &draft.edit_history,
            .vertical_navigation = &draft.vertical_navigation,
        };
    }

    fn deinit(self: *DraftComposer, alloc: std.mem.Allocator) void {
        self.picker.deinit(alloc);
    }

    fn insertionState(self: *DraftComposer) composer_insertion.State {
        return .{
            .edit = self.edit_state,
            .history = self.edit_history,
            .picker = &self.picker,
            .entities = self.entities,
            .vertical_navigation = self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    pub fn historyBoundary(self: *DraftComposer, alloc: std.mem.Allocator) void {
        self.edit_history.reset(alloc);
    }
};

const FakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/",
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    } = .{},
    transcript: std.ArrayList(u8) = .empty,
    next_image_id_counter: usize = 1,
    input_runtime: FakeInput = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    last_tone: ?types.NoticeTone = null,
    notice_count: usize = 0,
    capture_error: ?anyerror = null,
    snapshot_dir: ?[]const u8 = null,
    clipboard_read: clipboard_read.Runtime = .{},

    fn deinit(self: *FakeApp) void {
        self.clipboard_read.deinit(self.alloc);
        self.clearPendingImages(&self.main_agent);
        self.agent().pending_images.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.input_runtime.edit_state.deinit(self.alloc);
        self.input_runtime.entities.deinit(self.alloc);
    }

    fn clearPendingImages(self: *FakeApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.agent().pending_images.items);
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    pub fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }

    fn text(self: *const FakeApp) []const u8 {
        return self.transcript.items;
    }

    fn nextImageId(self: *FakeApp, _: anytype) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    fn peekNextImageId(self: *const FakeApp, _: anytype) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(self: *FakeApp, _: anytype, attachment: *types.ImageAttachment) !void {
        if (self.capture_error) |err| return err;
        const snapshot_dir = self.snapshot_dir orelse return;
        try image_attachments.captureImageSnapshot(self.alloc, attachment, snapshot_dir);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const FakeInput = struct {
    edit_state: edit_contract.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: FakeVerticalNavigation = .{},
    history_boundary_count: usize = 0,

    pub fn historyBoundary(self: *FakeInput, _: std.mem.Allocator) void {
        self.history_boundary_count += 1;
    }

    fn insertionState(self: *FakeInput) FakeInsertionState {
        return .{ .input = self };
    }
};

const FakeInsertionState = struct {
    input: *FakeInput,

    fn canInsert(
        self: FakeInsertionState,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        return edit_contract.canInsert(self.input.edit_state.input.items.len, inserted_len, max_len);
    }

    fn insertSliceAssumeCapacity(
        self: FakeInsertionState,
        _: std.mem.Allocator,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0) return;
        const insert_start = self.input.edit_state.cursor;
        self.input.edit_state.insertSliceAssumeCapacity(bytes);
        for (self.input.entities.image_tokens.items) |*token| {
            token.span = entity_spans.afterInsert(
                token.span,
                insert_start,
                bytes.len,
            ).?;
        }
    }
};

const FakeVerticalNavigation = struct {
    reset_count: usize = 0,

    fn reset(self: *FakeVerticalNavigation) void {
        self.reset_count += 1;
    }
};

fn expectTranscriptContains(app: *const FakeApp, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, app.text(), needle) != null);
}

fn writeTestImage(tmp: *std.testing.TmpDir, name: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
}

fn realTmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, name);
}

fn ownedTestAttachment(alloc: std.mem.Allocator, path: []const u8) !types.ImageAttachment {
    return .{
        .path = try alloc.dupe(u8, path),
        .media_type = try alloc.dupe(u8, "image/png"),
    };
}

fn testClipboardImage(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    source_dir_name: []const u8,
) !image_attachments.ClipboardImageAttachment {
    try tmp.dir.createDir(std.testing.io, source_dir_name, .default_dir);
    const source_sub_path = try std.Io.Dir.path.join(alloc, &.{ source_dir_name, "clipboard.png" });
    defer alloc.free(source_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = source_sub_path,
        .data = "\x89PNG\r\n\x1a\nclipboard",
    });
    const source_path = try realTmpPath(alloc, tmp, source_sub_path);
    defer alloc.free(source_path);
    return .{
        .attachment = try image_attachments.loadImageAttachment(alloc, source_path),
        .source_dir = try realTmpPath(alloc, tmp, source_dir_name),
    };
}

fn countSnapshotFiles(snapshot_dir: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, snapshot_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

test "attachPath reports usage for empty path" {
    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, " \t ");

    try expectTranscriptContains(&app, "usage: /image <path>");
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
}

test "attachPath inserts placeholder at cursor and tracks the attachment" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "shot.png");

    const path = try realTmpPath(alloc, &tmp, "shot.png");
    defer alloc.free(path);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqualStrings("image/png", app.agent().pending_images.items[0].media_type);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items[0].id);
    try std.testing.expectEqualStrings("[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "[Image #1]".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(
        entity_spans.Span{ .raw_start = 0, .raw_end = "[Image #1]".len },
        app.input_runtime.entities.image_tokens.items[0].span,
    );
    try expectTranscriptContains(&app, "attached image: shot.png");
    try tmp.dir.access(std.testing.io, "shot.png", .{});
}

test "attachPath resolves relative image paths from the workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try writeTestImage(&tmp, "workspace/shot.png");

    const workspace = try realTmpPath(alloc, &tmp, "workspace");
    defer alloc.free(workspace);
    const expected = try realTmpPath(alloc, &tmp, "workspace/shot.png");
    defer alloc.free(expected);

    var app = FakeApp{ .alloc = alloc, .workspace_root = workspace };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, "shot.png");

    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqualStrings(expected, app.agent().pending_images.items[0].path);
}

fn expectBadgeProjection(alloc: std.mem.Allocator, app: *const FakeApp, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try image_attachments.expandPlaceholdersWithBadges(
        alloc,
        &out.writer,
        app.input_runtime.edit_state.input.items,
        agents.screenAgentOf(app).pending_images.items,
        null,
    );
    try std.testing.expectEqualStrings(expected, out.written());
}

test "attachPath keeps image ids stable across turns" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "one.png");
    try writeTestImage(&tmp, "two.png");
    try writeTestImage(&tmp, "three.png");

    const one = try realTmpPath(alloc, &tmp, "one.png");
    defer alloc.free(one);
    const two = try realTmpPath(alloc, &tmp, "two.png");
    defer alloc.free(two);
    const three = try realTmpPath(alloc, &tmp, "three.png");
    defer alloc.free(three);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, one);
    try Commands(FakeApp).attachPath(&app, two);
    try std.testing.expectEqualStrings("[Image #1][Image #2]", app.input_runtime.edit_state.input.items);
    try expectBadgeProjection(alloc, &app, "[Image 1][Image 2]");

    // Submitting the turn releases the draft; the session id counter survives it.
    app.clearPendingImages(app.agent());
    app.input_runtime.edit_state.input.clearRetainingCapacity();
    app.input_runtime.edit_state.cursor = 0;

    try Commands(FakeApp).attachPath(&app, three);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.agent().pending_images.items[0].id);
    try std.testing.expectEqualStrings("[Image #3]", app.input_runtime.edit_state.input.items);
    try expectBadgeProjection(alloc, &app, "[Image 3]");
}

test "attachPath after a resumed session badges the next collision-free id" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "resumed.png");

    const path = try realTmpPath(alloc, &tmp, "resumed.png");
    defer alloc.free(path);

    const restored = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
        .{ .id = 2, .path = @constCast("/tmp/two.png"), .media_type = @constCast("image/png") },
    };
    const bounds = try image_attachments.calculate_next_image_id(&restored);

    var app = FakeApp{ .alloc = alloc, .next_image_id_counter = bounds.next_id };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqual(@as(usize, 3), app.agent().pending_images.items[0].id);
    try expectBadgeProjection(alloc, &app, "[Image 3]");
}

test "path and clipboard insertion recover from provider size rejection without mutating the draft" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "provider-too-large.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\n");
        try file.setLength(std.testing.io, image_attachments.max_image_bytes + 1);
    }
    try writeTestImage(&tmp, "next.png");

    const rejected_path = try realTmpPath(alloc, &tmp, "provider-too-large.png");
    defer alloc.free(rejected_path);
    const next_path = try realTmpPath(alloc, &tmp, "next.png");
    defer alloc.free(next_path);
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeApp{
        .alloc = alloc,
        .next_image_id_counter = 8,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    var existing = try ownedTestAttachment(alloc, "/tmp/existing.png");
    existing.id = 7;
    try app.agent().pending_images.append(alloc, existing);
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft [Image #7]");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Commands(FakeApp).attachPath(&app, rejected_path);

    try std.testing.expectEqualStrings("draft [Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.agent().pending_images.items[0].id);
    try std.testing.expectEqualStrings("/tmp/existing.png", app.agent().pending_images.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expectEqualStrings(
        "image exceeds the 20 MiB limit\n",
        app.text(),
    );
    try std.testing.expectEqual(@as(usize, 0), try countSnapshotFiles(snapshot_dir));

    app.transcript.clearRetainingCapacity();
    try Commands(FakeApp).attachPath(&app, next_path);

    try std.testing.expectEqual(@as(usize, 2), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 8), app.agent().pending_images.items[1].id);
    try std.testing.expect(std.mem.find(u8, app.input_runtime.edit_state.input.items, "[Image #8]") != null);
    try std.testing.expectEqual(@as(usize, 1), try countSnapshotFiles(snapshot_dir));
}

test "path and clipboard insertion propagate capture out of memory without a notice or mutation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "oom.png");

    const path = try realTmpPath(alloc, &tmp, "oom.png");
    defer alloc.free(path);

    var app = FakeApp{
        .alloc = alloc,
        .capture_error = error.OutOfMemory,
    };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try std.testing.expectError(
        error.OutOfMemory,
        Commands(FakeApp).attachPath(&app, path),
    );

    try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.notice_count);
}

test "path and clipboard insertion preserve cancellation timeout and fatal capture errors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "propagated.png");

    const path = try realTmpPath(alloc, &tmp, "propagated.png");
    defer alloc.free(path);

    for ([_]anyerror{
        error.Cancelled,
        error.TimedOut,
        error.InjectedCaptureFailure,
    }) |expected_error| {
        var app = FakeApp{
            .alloc = alloc,
            .capture_error = expected_error,
        };
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        try std.testing.expectError(
            expected_error,
            Commands(FakeApp).attachPath(&app, path),
        );

        try std.testing.expectEqualStrings("draft", app.input_runtime.edit_state.input.items);
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.notice_count);
    }
}

test "attachPath resets vertical intent after successful image append" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "reset.png");

    const path = try realTmpPath(alloc, &tmp, "reset.png");
    defer alloc.free(path);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.vertical_navigation.reset_count);
}

test "attachPath succeeds when placeholder exactly fills the input limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "exact.png");

    const path = try realTmpPath(alloc, &tmp, "exact.png");
    defer alloc.free(path);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendNTimes(alloc, 'x', FakeApp.input_byte_limit - "[Image #1]".len);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqual(FakeApp.input_byte_limit, app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expect(image_attachments.imageAttachmentsSortedById(app.agent().pending_images.items));
}

test "attachPath rejects when placeholder is one byte too long without mutating input or metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "full.png");

    const path = try realTmpPath(alloc, &tmp, "full.png");
    defer alloc.free(path);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendNTimes(alloc, 'x', FakeApp.input_byte_limit - "[Image #1]".len + 1);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    const before = try alloc.dupe(u8, app.input_runtime.edit_state.input.items);
    defer alloc.free(before);

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqualStrings(before, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.next_image_id_counter);
    try expectTranscriptContains(&app, "input is full");
    try tmp.dir.access(std.testing.io, "full.png", .{});
}

fn checkImageInsertionAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    fail_offset: ?usize,
    allocation_count: *usize,
) !void {
    const alloc = failing.allocator();
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = 7;

    const image = try ownedTestAttachment(alloc, "/tmp/reserved.png");
    const start_alloc_index = failing.alloc_index;
    if (fail_offset) |offset| {
        failing.fail_index = try std.math.add(
            usize,
            start_alloc_index,
            offset,
        );
    }

    _ = Commands(FakeApp).insertImageAtCursor(FakeApp, &app, image, .retained) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.image_tokens.items.len);
        try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
        return err;
    };

    allocation_count.* = failing.alloc_index - start_alloc_index;
    try std.testing.expectEqualStrings("[Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 8), app.next_image_id_counter);
}

test "insertImageAtCursor stays atomic across allocation failures" {
    var probe = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{});
    var allocation_count: usize = 0;
    try checkImageInsertionAllocationFailureIsAtomic(
        &probe,
        null,
        &allocation_count,
    );
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(
            testing_allocator.no_resize,
            .{},
        );
        var ignored_count: usize = 0;
        checkImageInsertionAllocationFailureIsAtomic(
            &failing,
            fail_offset,
            &ignored_count,
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "insertImageAtCursor rejects image id overflow without mutation" {
    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = std.math.maxInt(usize);
    const image = try ownedTestAttachment(alloc, "/tmp/overflow.png");

    try std.testing.expectError(
        error.Overflow,
        Commands(FakeApp).insertImageAtCursor(FakeApp, &app, image, .retained),
    );
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectEqual(std.math.maxInt(usize), app.next_image_id_counter);
}

test "temporary image source is removed after insertion and remapped to its snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    var loaded = try testClipboardImage(alloc, &tmp, "clipboard-source");
    const source_dir = try alloc.dupe(u8, loaded.source_dir);
    defer alloc.free(source_dir);

    var app = FakeApp{
        .alloc = alloc,
        .snapshot_dir = snapshot_dir,
    };
    defer app.deinit();
    const result = try Commands(FakeApp).insertImageAtCursor(
        FakeApp,
        &app,
        loaded.takeAttachment(),
        .temporary,
    );
    loaded.deinit(alloc);

    try std.testing.expectEqual(InsertImageResult.inserted, result);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, source_dir, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    const pending = app.agent().pending_images.items[0];
    try std.testing.expectEqualStrings(pending.snapshot_path.?, pending.path);
    var verified = try image_attachments.loadVerifiedSnapshot(
        alloc,
        pending,
        .{},
    );
    defer verified.deinit(alloc);
}

test "temporary image source is removed on input full rejection and capture failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    {
        var loaded = try testClipboardImage(alloc, &tmp, "clipboard-full");
        const source_dir = try alloc.dupe(u8, loaded.source_dir);
        defer alloc.free(source_dir);
        var app = FakeApp{
            .alloc = alloc,
            .snapshot_dir = snapshot_dir,
        };
        defer app.deinit();
        try app.input_runtime.edit_state.input.appendNTimes(alloc, 'x', FakeApp.input_byte_limit);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

        const result = try Commands(FakeApp).insertImageAtCursor(
            FakeApp,
            &app,
            loaded.takeAttachment(),
            .temporary,
        );
        loaded.deinit(alloc);

        try std.testing.expectEqual(InsertImageResult.input_full, result);
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, source_dir, .{}),
        );
    }

    for ([_]anyerror{ error.ImageTooLarge, error.OutOfMemory }) |capture_error| {
        const source_name = if (capture_error == error.ImageTooLarge)
            "clipboard-rejected"
        else
            "clipboard-oom";
        var loaded = try testClipboardImage(alloc, &tmp, source_name);
        const source_dir = try alloc.dupe(u8, loaded.source_dir);
        defer alloc.free(source_dir);
        var app = FakeApp{
            .alloc = alloc,
            .capture_error = capture_error,
            .snapshot_dir = snapshot_dir,
        };
        defer app.deinit();

        if (capture_error == error.ImageTooLarge) {
            const result = try Commands(FakeApp).insertImageAtCursor(
                FakeApp,
                &app,
                loaded.takeAttachment(),
                .temporary,
            );
            try std.testing.expectEqual(InsertImageResult.rejected, result);
        } else {
            try std.testing.expectError(
                capture_error,
                Commands(FakeApp).insertImageAtCursor(
                    FakeApp,
                    &app,
                    loaded.takeAttachment(),
                    .temporary,
                ),
            );
        }
        loaded.deinit(alloc);

        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, source_dir, .{}),
        );
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    }
}

test "attachPath inserts at the cursor position with surrounding text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "shot.png");

    const path = try realTmpPath(alloc, &tmp, "shot.png");
    defer alloc.free(path);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "abXY");
    app.input_runtime.edit_state.cursor = 2;

    try Commands(FakeApp).attachPath(&app, path);

    try std.testing.expectEqualStrings("ab[Image #1]XY", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, "ab[Image #1]".len), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.history_boundary_count);
}

test "attachPath at distinct cursor positions assigns ids in order of attachment" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(&tmp, "a.png");
    try writeTestImage(&tmp, "b.png");

    const path_a = try realTmpPath(alloc, &tmp, "a.png");
    defer alloc.free(path_a);
    const path_b = try realTmpPath(alloc, &tmp, "b.png");
    defer alloc.free(path_b);

    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "hello");
    app.input_runtime.edit_state.cursor = 5;

    try Commands(FakeApp).attachPath(&app, path_a);

    app.input_runtime.edit_state.cursor = 0;
    try Commands(FakeApp).attachPath(&app, path_b);

    try std.testing.expectEqualStrings("[Image #2]hello[Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), app.agent().pending_images.items[1].id);
    try std.testing.expect(image_attachments.imageAttachmentsSortedById(app.agent().pending_images.items));
}

test "attachPath reports missing and unsupported image errors" {
    const alloc = std.testing.allocator;
    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();

        try Commands(FakeApp).attachPath(&app, "/definitely/missing/image.png");

        try expectTranscriptContains(&app, "image file not found");
        try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var file = try tmp.dir.createFile(std.testing.io, "note.txt", .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "plain text");
        }
        const path = try realTmpPath(alloc, &tmp, "note.txt");
        defer alloc.free(path);

        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();

        try Commands(FakeApp).attachPath(&app, path);

        try expectTranscriptContains(&app, "unsupported image type");
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    }
}

test "managePending reports empty lists populated lists and clear" {
    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).managePending(&app, (&app).agent(), "");
    try expectTranscriptContains(&app, "no pending images");
    app.transcript.clearRetainingCapacity();

    try app.agent().pending_images.append(alloc, .{
        .path = try alloc.dupe(u8, "/tmp/a.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    });
    try app.agent().pending_images.append(alloc, .{
        .path = try alloc.dupe(u8, "/tmp/b.jpeg"),
        .media_type = try alloc.dupe(u8, "image/jpeg"),
    });

    try Commands(FakeApp).managePending(&app, (&app).agent(), "list");
    try std.testing.expectEqualStrings(
        "2 pending\n - a.png (image/png)\n - b.jpeg (image/jpeg)\n",
        app.text(),
    );

    app.transcript.clearRetainingCapacity();
    try Commands(FakeApp).managePending(&app, (&app).agent(), "clear");

    try expectTranscriptContains(&app, "cleared pending images");
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
}

test "attachClipboard is silent on unsupported platforms" {
    if (@import("builtin").target.os.tag == .macos) return;

    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).attachClipboard(&app);

    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

/// Stands in for osascript in the clipboard tests: blocks until released,
/// then hands back a PNG in a temp folder. No test reads the real clipboard.
const HeldClipboard = struct {
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),

    fn loader(self: *HeldClipboard) clipboard_read.Loader {
        return .{ .ctx = self, .load = load };
    }

    fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, budget: image_attachments.CaptureBudget) anyerror!image_attachments.ClipboardImageAttachment {
        const self: *HeldClipboard = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        var waited_ms: usize = 0;
        while (!self.release.load(.seq_cst)) : (waited_ms += 1) {
            try budget.check();
            if (waited_ms > 10_000) return error.TestClipboardNotReleased;
            @import("../shared/io.zig").sleep(std.time.ns_per_ms);
        }
        const dir = try image_attachments.createTempSnapshotDir(alloc);
        errdefer {
            image_attachments.cleanupSnapshotDir(dir);
            alloc.free(dir);
        }
        const path = try std.Io.Dir.path.join(alloc, &.{ dir, "clipboard.png" });
        errdefer alloc.free(path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "\x89PNG\r\n\x1a\nheld clipboard" });
        return .{
            .attachment = .{ .path = path, .media_type = try alloc.dupe(u8, "image/png") },
            .source_dir = dir,
        };
    }
};

fn takeClipboardRead(app: *FakeApp) !clipboard_read.Finished {
    var waited_ms: usize = 0;
    while (true) : (waited_ms += 1) {
        if (app.clipboard_read.take()) |finished| return finished;
        if (waited_ms > 10_000) return error.TestTimedOut;
        @import("../shared/io.zig").sleep(std.time.ns_per_ms);
    }
}

test "attachClipboard returns while the clipboard export blocks and refuses a second read with a notice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var held: HeldClipboard = .{};
    var app = FakeApp{ .alloc = alloc, .snapshot_dir = snapshot_dir, .clipboard_read = .{ .loader = held.loader() } };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "typed ");
    app.input_runtime.edit_state.cursor = "typed ".len;

    try Commands(FakeApp).attachClipboard(&app);
    try std.testing.expectEqualStrings("reading clipboard\n", app.text());
    try std.testing.expect(app.clipboard_read.take() == null);
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);

    try Commands(FakeApp).attachClipboard(&app);
    try std.testing.expectEqualStrings("reading clipboard\nalready reading clipboard\n", app.text());

    held.release.store(true, .seq_cst);
    var finished = try takeClipboardRead(&app);
    defer finished.outcome.deinit(alloc);
    try std.testing.expectEqual(@as(?*const anyopaque, app.agent()), finished.requester);
    try Commands(FakeApp).finishClipboard(&app, &finished.outcome, null);

    try std.testing.expectEqualStrings("typed [Image #1]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(u32, 1), held.calls.load(.seq_cst));
}

test "attachClipboard reports a worker that failed to start" {
    const alloc = std.testing.allocator;
    var held: HeldClipboard = .{};
    var app = FakeApp{ .alloc = alloc, .clipboard_read = .{ .loader = held.loader(), .test_spawn_error = error.SystemResources } };
    defer app.deinit();

    try Commands(FakeApp).attachClipboard(&app);
    try std.testing.expectEqualStrings("failed to paste clipboard image: SystemResources\n", app.text());
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expectEqual(@as(u32, 0), held.calls.load(.seq_cst));
}

test "finishClipboard puts the image into a hidden agent's stashed draft and leaves the composer alone" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realTmpPath(alloc, &tmp, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);

    var app = FakeApp{ .alloc = alloc, .snapshot_dir = snapshot_dir };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "visible draft");
    app.input_runtime.edit_state.cursor = 7;

    var stash: composer_stash.State = .{};
    defer stash.deinit(alloc);
    try stash.edit.input.appendSlice(alloc, "hidden draft");
    stash.edit.cursor = "hidden".len;

    var outcome: clipboard_read.Outcome = .{ .image = try testClipboardImage(alloc, &tmp, "clipboard-hidden") };
    defer outcome.deinit(alloc);
    try Commands(FakeApp).finishClipboard(&app, &outcome, &stash);

    try std.testing.expectEqualStrings("hidden[Image #1] draft", stash.edit.input.items);
    try std.testing.expectEqual(@as(usize, "hidden[Image #1]".len), stash.edit.cursor);
    try std.testing.expectEqual(@as(usize, 1), stash.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, "hidden".len), stash.entities.image_tokens.items[0].span.raw_start);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    // The composer belongs to the agent on screen and is untouched.
    try std.testing.expectEqualStrings("visible draft", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 7), app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.history_boundary_count);
}

test "finishClipboard reports a full composer and removes the clipboard's temp file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendNTimes(alloc, 'x', FakeApp.input_byte_limit);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    var outcome: clipboard_read.Outcome = .{ .image = try testClipboardImage(alloc, &tmp, "clipboard-full-finish") };
    const source_dir = try alloc.dupe(u8, outcome.image.source_dir);
    defer alloc.free(source_dir);
    try Commands(FakeApp).finishClipboard(&app, &outcome, null);
    outcome.deinit(alloc);

    try std.testing.expectEqualStrings("input is full; image not attached\n", app.text());
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectEqual(FakeApp.input_byte_limit, app.input_runtime.edit_state.input.items.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, source_dir, .{}));
}

test "finishClipboard shows a missing image, a timeout, and a failure as notices" {
    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    var no_image: clipboard_read.Outcome = .no_image;
    try Commands(FakeApp).finishClipboard(&app, &no_image, null);
    var timed_out: clipboard_read.Outcome = .timed_out;
    try Commands(FakeApp).finishClipboard(&app, &timed_out, null);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    var failed: clipboard_read.Outcome = .{ .failed = error.AccessDenied };
    try Commands(FakeApp).finishClipboard(&app, &failed, null);

    try std.testing.expectEqualStrings(
        "no image found on clipboard\nclipboard read timed out\nfailed to paste clipboard image: AccessDenied\n",
        app.text(),
    );
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
}

test "dropClipboard tells the user an image was not attached and only logs other outcomes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    var no_image: clipboard_read.Outcome = .no_image;
    try Commands(FakeApp).dropClipboard(&app, &no_image);
    try std.testing.expectEqual(@as(usize, 0), app.notice_count);

    var image: clipboard_read.Outcome = .{ .image = try testClipboardImage(alloc, &tmp, "clipboard-dropped") };
    const source_dir = try alloc.dupe(u8, image.image.source_dir);
    defer alloc.free(source_dir);
    try Commands(FakeApp).dropClipboard(&app, &image);
    image.deinit(alloc);
    try std.testing.expectEqualStrings("clipboard image not attached: the agent that asked has closed\n", app.text());
    try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, source_dir, .{}));
}
