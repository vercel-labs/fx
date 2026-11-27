//! Asks the terminal for the clipboard image when fx cannot read the
//! clipboard itself, such as over SSH, and attaches the image once the reply
//! is complete. `src/ui/terminal/clipboard_protocol.zig` owns the protocol;
//! the App's terminal input runtime owns the reader.

const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const clipboard_protocol = @import("../../ui/terminal/clipboard_protocol.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const io_mod = @import("../shared/io.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");

const paste_event_denied_notice =
    "The terminal blocked fx from reading the clipboard, so fx turned off paste events. Paste again.";

fn inputLimitsForApp(comptime App: type) paste_framing.InputLimits {
    if (comptime @hasDecl(App, "input_limits")) return App.input_limits;
    if (comptime @hasDecl(App, "input_byte_limit")) return paste_framing.InputLimits.single(App.input_byte_limit);
    return paste_framing.default_input_limits;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Writes the request, unless one is still outstanding.
        pub fn request(app: *App) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            reader.begin(io_mod.milliTimestamp(), image_attachments.max_image_bytes) catch {
                debug_trace.logf("clipboard", "clipboard request skipped reason=request_pending", .{});
                try app.writeDomainNotice(.{
                    .topic = "images",
                    .tone = .neutral,
                    .body = "still waiting for the clipboard image from the terminal",
                }, true);
                return;
            };
            app.terminal_input_runtime.pending_clipboard_read = .ctrl_v_image;
            app.terminal.requestClipboardImage() catch |err| {
                reader.cancel();
                app.terminal_input_runtime.pending_clipboard_read = .none;
                debug_trace.logf("clipboard", "clipboard request write failed err={s}", .{@errorName(err)});
                const line = try app.alloc.print("failed to paste clipboard image: {s}", .{@errorName(err)});
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                return;
            };
            debug_trace.logf("clipboard", "clipboard image requested from terminal", .{});
        }

        /// Applies the reader's deadlines and handles finished requests and
        /// paste-event listings. Runs after the theme monitor's `poll` and
        /// before more input.
        pub fn collectFacts(app: *App) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            const now_ms = io_mod.milliTimestamp();
            if (app.terminal_input_runtime.terminal_theme_monitor.takeDroppedClipboardStart()) {
                reader.dropReplyStart(app.alloc, now_ms);
            }
            reader.poll(app.alloc, now_ms);
            try handleImageOutcome(app);
            try handleTextOutcome(app);
            try handlePasteEventOutcome(app, now_ms);
        }

        fn handleImageOutcome(app: *App) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            var outcome = reader.takeOutcome() orelse return;
            defer outcome.deinit(app.alloc);
            const origin = app.terminal_input_runtime.pending_clipboard_read;
            app.terminal_input_runtime.pending_clipboard_read = .none;
            debug_trace.logf("clipboard", "clipboard reply outcome={s}", .{@tagName(outcome)});

            if (outcome == .denied and origin == .paste_event_image) {
                try disablePasteEventsAfterDenial(app);
                return;
            }
            // The model picker may have taken the composer while the terminal
            // answered; an image placeholder would land in its query.
            if (outcome == .image and input_paste_runtime.PasteEditRuntime(App).modelPickerBorrowsComposer(app)) {
                debug_trace.logf(
                    "clipboard",
                    "clipboard image dropped bytes={d} reason=model_picker_borrows_composer",
                    .{outcome.image.items.len},
                );
                try app.writeDomainNotice(.{
                    .topic = "images",
                    .tone = .neutral,
                    .body = "image not attached while the model picker is open; paste again",
                }, true);
                return;
            }
            try image_commands.Commands(App).attachTerminalClipboardOutcome(app, outcome);
        }

        fn handleTextOutcome(app: *App) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            var outcome = reader.takeTextOutcome() orelse return;
            defer outcome.deinit(app.alloc);
            const origin = app.terminal_input_runtime.pending_clipboard_read;
            app.terminal_input_runtime.pending_clipboard_read = .none;
            debug_trace.logf("clipboard", "clipboard text reply outcome={s}", .{@tagName(outcome)});

            const kept = switch (origin) {
                .paste_event_text => |target| target,
                else => return,
            };
            const target: input_paste_runtime.PasteTarget = .{ .capture = .{
                .owner = kept.owner,
                .buffer_limit = kept.buffer_limit,
            } };

            switch (outcome) {
                .text => |bytes| {
                    try input_paste_runtime.PasteEditRuntime(App).pasteDecodedText(
                        app,
                        agents.screenAgentOf(app),
                        target,
                        bytes.items,
                        kept.max_input_len,
                    );
                },
                .no_text => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .neutral,
                    .body = "clipboard is empty",
                }, true),
                .denied => try disablePasteEventsAfterDenial(app),
                .too_large => try reportTextTooLarge(app, kept),
                .busy => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "terminal clipboard is busy; paste again",
                }, true),
                .timed_out => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "terminal didn't send the clipboard text; paste again",
                }, true),
                .malformed => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "terminal sent unreadable clipboard text; paste again",
                }, true),
                .unsupported => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "this terminal can't send clipboard text",
                }, true),
            }
        }

        fn reportTextTooLarge(app: *App, kept: @FieldType(@TypeOf(app.terminal_input_runtime.pending_clipboard_read), "paste_event_text")) !void {
            if (kept.owner == .auth_code) {
                app.shell.render_requests.request(.footer);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "The authorization code is too long.",
                }, true);
                return;
            }
            const scalar_owner: text_scalar.Owner = switch (kept.owner) {
                .composer => .composer,
                .question_freeform => .question_freeform,
                .approval_amendment => .approval_amendment,
                .none, .decision_prompt, .auth_code => return,
            };
            try input_limit_feedback.report(App, app, scalar_owner, kept.buffer_limit +| 1);
        }

        fn handlePasteEventOutcome(app: *App, now_ms: i64) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            var outcome = reader.takePasteEventOutcome() orelse return;
            defer outcome.deinit(app.alloc);
            debug_trace.logf("clipboard", "paste event outcome={s}", .{@tagName(outcome)});

            switch (outcome) {
                .busy => try writeClipboardBusyNotice(app),
                .timed_out => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "terminal didn't send the clipboard paste; paste again",
                }, true),
                .malformed => try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .@"error",
                    .body = "terminal sent an unreadable clipboard paste; paste again",
                }, true),
                .paste_event => |*event| try startPasteEventRead(app, event, now_ms),
            }
        }

        fn startPasteEventRead(
            app: *App,
            event: *clipboard_protocol.PasteEvent,
            now_ms: i64,
        ) !void {
            if (comptime @hasDecl(App, "openAgentsMenu")) {
                _ = app_agents_runtime.Runtime(App).closeMenu(app);
            }
            if (comptime @hasField(App, "auth") and @hasDecl(@TypeOf(app.auth), "signInEntryActive")) {
                _ = app_auth_runtime.Runtime(App).routeAuthPickerEscapeAction(app, .paste_start);
            }

            const paste_rt = input_paste_runtime.PasteEditRuntime(App);
            const agent = agents.screenAgentOf(app);
            const limits = inputLimitsForApp(App);
            const target = paste_rt.resolvePasteTarget(app, agent, limits.composer_bytes);
            const capture = switch (target) {
                .capture => |capture| capture,
                .drop => |reason| {
                    debug_trace.logf("clipboard", "paste event dropped reason={s}", .{@tagName(reason)});
                    return;
                },
            };
            if (capture.owner == .decision_prompt) {
                debug_trace.logf("clipboard", "paste event dropped reason=decision_prompt", .{});
                return;
            }

            const image_allowed = capture.owner == .composer and !paste_rt.modelPickerBorrowsComposer(app);
            const mime = clipboard_protocol.pickPasteMime(event.mimes.items, image_allowed) orelse {
                const empty = std.mem.trim(u8, event.mimes.items, " \t\n\r\x0b\x0c").len == 0;
                debug_trace.logf(
                    "clipboard",
                    "paste event skipped mimes_bytes={d} reason={s}",
                    .{ event.mimes.items.len, if (empty) "empty_mime_list" else "unsupported_mime" },
                );
                try app.writeDomainNotice(.{
                    .topic = "input",
                    .tone = .neutral,
                    .body = if (empty) "clipboard is empty" else "the clipboard holds nothing fx can paste",
                }, true);
                return;
            };

            var req_buf: [512]u8 = undefined;
            defer std.crypto.secureZero(u8, &req_buf);
            var req_writer: std.Io.Writer = .fixed(&req_buf);
            try clipboard_protocol.writePasteReadRequest(
                &req_writer,
                event.password.items,
                event.location,
                mime,
            );
            const request_bytes = req_writer.buffered();

            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            if (mime == .png) {
                reader.beginPasteImage(now_ms, image_attachments.max_image_bytes) catch {
                    debug_trace.logf("clipboard", "paste event read skipped reason=request_pending", .{});
                    try writeClipboardBusyNotice(app);
                    return;
                };
                app.terminal_input_runtime.pending_clipboard_read = .paste_event_image;
            } else {
                reader.beginText(now_ms, capture.buffer_limit +| 1, mime) catch {
                    debug_trace.logf("clipboard", "paste event read skipped reason=request_pending", .{});
                    try writeClipboardBusyNotice(app);
                    return;
                };
                app.terminal_input_runtime.pending_clipboard_read = .{ .paste_event_text = .{
                    .owner = capture.owner,
                    .buffer_limit = capture.buffer_limit,
                    .max_input_len = limits.forOwner(capture.owner),
                } };
            }

            app.terminal.requestClipboardPasteRead(request_bytes) catch |err| {
                reader.cancel();
                app.terminal_input_runtime.pending_clipboard_read = .none;
                debug_trace.logf("clipboard", "paste event read write failed err={s}", .{@errorName(err)});
                const line = try app.alloc.print("failed to read clipboard paste: {s}", .{@errorName(err)});
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "input", .tone = .@"error", .body = line }, true);
                return;
            };
        }

        fn writeClipboardBusyNotice(app: *App) !void {
            try app.writeDomainNotice(.{
                .topic = "input",
                .tone = .@"error",
                .body = "terminal clipboard is busy; paste again",
            }, true);
        }

        fn disablePasteEventsAfterDenial(app: *App) !void {
            app.terminal_input_runtime.paste_events_enabled = false;
            app.terminal.disablePasteEvents() catch |err| {
                debug_trace.logf("clipboard", "paste_events_disable_failed err={s}", .{@errorName(err)});
            };
            try app.writeDomainNotice(.{
                .topic = "input",
                .tone = .@"error",
                .body = paste_event_denied_notice,
            }, true);
        }
    };
}

const TestStd = @import("std");
const TestApprovalPrompt = @import("../permissions/approval_prompt.zig");
const TestAuthRuntime = @import("../auth/auth_runtime.zig");
const TestClipboardProtocol = @import("../../ui/terminal/clipboard_protocol.zig");
const TestCoreInputRuntime = @import("../input/runtime.zig");
const TestQuestionPrompt = @import("../agent/question_prompt.zig");
const TestShellRuntime = @import("../../ui/shell_runtime.zig");
const TestTranscriptRuntime = @import("../../ui/transcript/runtime.zig");
const TestTypes = @import("../shared/types.zig");
const TestUiInput = @import("../../ui/input/runtime.zig");

const ClipboardTestFakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: TestStd.mem.Allocator,
    workspace_root: []const u8 = "/",
    terminal_input_runtime: TestUiInput.Runtime = .{},
    input_runtime: TestCoreInputRuntime.Runtime = .{},
    shell: TestTranscriptRuntime.TranscriptRuntime = .{},
    terminal: TestShellRuntime.TerminalState = .{},
    auth: TestAuthRuntime.Runtime = .{},
    main_agent: struct {
        pending_images: TestStd.ArrayList(TestTypes.ImageAttachment) = .empty,
        question_prompt: TestQuestionPrompt.QuestionPrompt = .{},
        approval_prompt: TestApprovalPrompt.ApprovalPrompt = .{},
    } = .{},
    next_image_id_counter: usize = 1,
    notice_count: usize = 0,
    notice_body: TestStd.ArrayList(u8) = .empty,
    notice_tone: ?TestTypes.NoticeTone = null,
    write_buf: [1024]u8 = undefined,
    write_sink: TestStd.Io.Writer = undefined,

    fn attachWriteSink(self: *ClipboardTestFakeApp) void {
        self.write_sink = .fixed(&self.write_buf);
        self.terminal.test_write_sink = &self.write_sink;
    }

    fn clearWrittenBytes(self: *ClipboardTestFakeApp) void {
        self.attachWriteSink();
    }

    fn deinit(self: *ClipboardTestFakeApp) void {
        self.terminal_input_runtime.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.auth.deinit(self.alloc);
        self.main_agent.question_prompt.deinit(self.alloc);
        self.main_agent.approval_prompt.deinit(self.alloc);
        for (self.main_agent.pending_images.items) |image| TestTypes.freeImageAttachment(self.alloc, image);
        self.main_agent.pending_images.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }

    pub fn writeDomainNotice(self: *ClipboardTestFakeApp, notice: TestTypes.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
        self.notice_tone = notice.tone;
        self.notice_body.clearRetainingCapacity();
        try self.notice_body.appendSlice(self.alloc, notice.body);
    }

    pub fn nextImageId(self: *ClipboardTestFakeApp, _: anytype) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const ClipboardTestFakeApp, _: anytype) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(_: *ClipboardTestFakeApp, _: anytype, _: *TestTypes.ImageAttachment) !void {}

    fn writtenBytes(self: *ClipboardTestFakeApp) []const u8 {
        return self.write_sink.buffered();
    }
};

fn deliverTestClipboardPacket(app: *ClipboardTestFakeApp, body: []const u8) void {
    const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
    reader.beginPacket(app.alloc, 10);
    for (body) |byte| _ = reader.feedOwnedByte(app.alloc, byte, 10);
    for ("\x1b\\") |byte| _ = reader.feedOwnedByte(app.alloc, byte, 10);
}

fn deliverTestListing(app: *ClipboardTestFakeApp, ok_meta: []const u8, mimes: []const u8) !void {
    const ok_body = try TestStd.fmt.allocPrint(app.alloc, "type=read:status=OK{s}", .{ok_meta});
    defer app.alloc.free(ok_body);
    deliverTestClipboardPacket(app, ok_body);

    const b64_mimes = try app.alloc.alloc(u8, TestStd.base64.standard.Encoder.calcSize(mimes.len));
    defer app.alloc.free(b64_mimes);
    _ = TestStd.base64.standard.Encoder.encode(b64_mimes, mimes);
    const data_body = try TestStd.fmt.allocPrint(app.alloc, "type=read:status=DATA:mime=Lg==;{s}", .{b64_mimes});
    defer app.alloc.free(data_body);
    deliverTestClipboardPacket(app, data_body);

    deliverTestClipboardPacket(app, "type=read:status=DONE");
}

fn deliverTestDataChunk(app: *ClipboardTestFakeApp, mime_b64: []const u8, bytes: []const u8) !void {
    const b64 = try app.alloc.alloc(u8, TestStd.base64.standard.Encoder.calcSize(bytes.len));
    defer app.alloc.free(b64);
    _ = TestStd.base64.standard.Encoder.encode(b64, bytes);
    const data_body = try TestStd.fmt.allocPrint(app.alloc, "type=read:status=DATA:mime={s};{s}", .{ mime_b64, b64 });
    defer app.alloc.free(data_body);
    deliverTestClipboardPacket(app, data_body);
}

test "terminal clipboard listing with text writes exact request and pastes reply into composer" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        app.writtenBytes(),
    );
    try TestStd.testing.expect(app.terminal_input_runtime.terminal_clipboard_reader.pending());

    deliverTestClipboardPacket(&app, "type=read:status=OK");
    try deliverTestDataChunk(&app, "dGV4dC9wbGFpbg==", "pasted via 5522");
    deliverTestClipboardPacket(&app, "type=read:status=DONE");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings("pasted via 5522", app.input_runtime.edit_state.input.items);
    try TestStd.testing.expect(!app.terminal_input_runtime.terminal_clipboard_reader.pending());
}

test "terminal clipboard listing with image/png in composer requests image/png without DECRQM" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "image/png");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;aW1hZ2UvcG5n\x1b\\",
        app.writtenBytes(),
    );
    try TestStd.testing.expect(app.terminal_input_runtime.terminal_clipboard_reader.pending());
}

test "terminal clipboard listing with image/png and text/plain in composer requests text" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "image/png text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        app.writtenBytes(),
    );
    try TestStd.testing.expect(app.terminal_input_runtime.terminal_clipboard_reader.pending());
}

test "terminal clipboard paste event while Ctrl+V read is open writes busy notice and sends no request" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try Runtime(ClipboardTestFakeApp).request(&app);
    app.clearWrittenBytes();

    var pw: TestStd.ArrayList(u8) = .empty;
    errdefer pw.deinit(alloc);
    try pw.appendSlice(alloc, "secret123");
    var mimes: TestStd.ArrayList(u8) = .empty;
    errdefer mimes.deinit(alloc);
    try mimes.appendSlice(alloc, "text/plain");
    app.terminal_input_runtime.terminal_clipboard_reader.paste_event_outcome = .{ .paste_event = .{
        .password = pw,
        .location = .clipboard,
        .mimes = mimes,
    } };

    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings("", app.writtenBytes());
    try TestStd.testing.expectEqual(@as(usize, 1), app.notice_count);
    try TestStd.testing.expectEqual(TestTypes.NoticeTone.@"error", app.notice_tone.?);
    try TestStd.testing.expectEqualStrings("terminal clipboard is busy; paste again", app.notice_body.items);
    try TestStd.testing.expectEqual(TestUiInput.PendingClipboardRead.ctrl_v_image, app.terminal_input_runtime.pending_clipboard_read);
}

test "terminal clipboard listing with image/png while question is open requests text" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    const opts = [_]TestTypes.QuestionOption{
        .{ .label = "Yes", .description = null },
    };
    const entries = [_]TestTypes.QuestionBatchEntry{
        .{ .question = "Answer?", .options = &opts },
    };
    try app.main_agent.question_prompt.syncFrom(alloc, &entries);
    app.main_agent.question_prompt.moveChoice(-1);

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "image/png text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        app.writtenBytes(),
    );

    deliverTestClipboardPacket(&app, "type=read:status=OK");
    try deliverTestDataChunk(&app, "dGV4dC9wbGFpbg==", "custom answer");
    deliverTestClipboardPacket(&app, "type=read:status=DONE");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings(
        "custom answer",
        app.main_agent.question_prompt.entries.items[0].freeform_buffer.items,
    );
}

test "terminal clipboard listing while decision prompt is open sends no request" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    const opts = [_]TestTypes.QuestionOption{
        .{ .label = "Yes", .description = null },
    };
    const entries = [_]TestTypes.QuestionBatchEntry{
        .{ .question = "Choose", .options = &opts },
    };
    try app.main_agent.question_prompt.syncFrom(alloc, &entries);

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings("", app.writtenBytes());
    try TestStd.testing.expect(!app.terminal_input_runtime.terminal_clipboard_reader.pending());
}

test "terminal clipboard empty listing shows notice and sends no request" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqualStrings("", app.writtenBytes());
    try TestStd.testing.expectEqual(@as(usize, 1), app.notice_count);
    try TestStd.testing.expectEqualStrings("clipboard is empty", app.notice_body.items);
}

test "terminal clipboard paste-event denial disables mode 5522, shows notice, and stops re-arming 5522h" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);
    app.clearWrittenBytes();

    deliverTestClipboardPacket(&app, "type=read:status=EPERM");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expect(!app.terminal_input_runtime.paste_events_enabled);
    try TestStd.testing.expectEqualStrings("\x1b[?5522l", app.writtenBytes());
    try TestStd.testing.expectEqualStrings(
        "The terminal blocked fx from reading the clipboard, so fx turned off paste events. Paste again.",
        app.notice_body.items,
    );

    app.clearWrittenBytes();
    try app.terminal.enableBracketedPaste(app.terminal_input_runtime.paste_events_enabled);
    if (@import("../shared/io.zig").getenv("TMUX") == null) {
        try TestStd.testing.expectEqualStrings("\x1b[?2004h", app.writtenBytes());
    }
    try TestStd.testing.expect(TestStd.mem.find(u8, app.writtenBytes(), "\x1b[?5522h") == null);
}

test "terminal clipboard paste-event image denial disables mode 5522 while Ctrl+V denial leaves it on" {
    const alloc = TestStd.testing.allocator;
    // Paste-event image denial disables mode 5522.
    {
        var app = ClipboardTestFakeApp{ .alloc = alloc };
        defer app.deinit();
        app.attachWriteSink();

        try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "image/png");
        try Runtime(ClipboardTestFakeApp).collectFacts(&app);
        app.clearWrittenBytes();

        deliverTestClipboardPacket(&app, "type=read:status=EPERM");
        try Runtime(ClipboardTestFakeApp).collectFacts(&app);

        try TestStd.testing.expect(!app.terminal_input_runtime.paste_events_enabled);
        try TestStd.testing.expectEqualStrings("\x1b[?5522l", app.writtenBytes());
        try TestStd.testing.expectEqualStrings(
            "The terminal blocked fx from reading the clipboard, so fx turned off paste events. Paste again.",
            app.notice_body.items,
        );
    }

    // Ctrl+V denial keeps mode 5522 on and uses image_commands notice.
    {
        var app = ClipboardTestFakeApp{ .alloc = alloc };
        defer app.deinit();
        app.attachWriteSink();

        try Runtime(ClipboardTestFakeApp).request(&app);
        app.clearWrittenBytes();
        deliverTestClipboardPacket(&app, "type=read:status=EPERM");
        try Runtime(ClipboardTestFakeApp).collectFacts(&app);

        try TestStd.testing.expect(app.terminal_input_runtime.paste_events_enabled);
        try TestStd.testing.expectEqualStrings("", app.writtenBytes());
        try TestStd.testing.expectEqualStrings(
            "clipboard access denied; allow it in the terminal and paste again",
            app.notice_body.items,
        );
    }
}

test "terminal clipboard text over target limit triggers input limit feedback" {
    const alloc = TestStd.testing.allocator;
    var app = ClipboardTestFakeApp{ .alloc = alloc };
    defer app.deinit();
    app.attachWriteSink();

    try deliverTestListing(&app, ":pw=c2VjcmV0MTIz", "text/plain");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    const oversized = try alloc.alloc(u8, ClipboardTestFakeApp.input_byte_limit + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');

    deliverTestClipboardPacket(&app, "type=read:status=OK");
    try deliverTestDataChunk(&app, "dGV4dC9wbGFpbg==", oversized[0..2048]);
    try deliverTestDataChunk(&app, "dGV4dC9wbGFpbg==", oversized[2048..]);
    deliverTestClipboardPacket(&app, "type=read:status=DONE");
    try Runtime(ClipboardTestFakeApp).collectFacts(&app);

    try TestStd.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    try TestStd.testing.expectEqualStrings(
        "That edit exceeds the local prompt safety limit and was not applied.",
        app.notice_body.items,
    );
}
