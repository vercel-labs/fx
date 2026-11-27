//! Asks the terminal for the clipboard image when fx cannot read the
//! clipboard itself, such as over SSH, and attaches the image once the reply
//! is complete. `src/ui/terminal/clipboard_protocol.zig` owns the protocol;
//! the App's terminal input runtime owns the reader.

const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const io_mod = @import("../shared/io.zig");

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
            app.terminal.requestClipboardImage() catch |err| {
                reader.cancel();
                debug_trace.logf("clipboard", "clipboard request write failed err={s}", .{@errorName(err)});
                const line = try app.alloc.print("failed to paste clipboard image: {s}", .{@errorName(err)});
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                return;
            };
            debug_trace.logf("clipboard", "clipboard image requested from terminal", .{});
        }

        /// Applies the reader's deadlines and handles a finished request. It
        /// runs after the theme monitor's `poll` and before more input.
        pub fn collectFacts(app: *App) !void {
            const reader = &app.terminal_input_runtime.terminal_clipboard_reader;
            const now_ms = io_mod.milliTimestamp();
            if (app.terminal_input_runtime.terminal_theme_monitor.takeDroppedClipboardStart()) {
                reader.dropReplyStart(app.alloc, now_ms);
            }
            reader.poll(app.alloc, now_ms);
            var outcome = reader.takeOutcome() orelse return;
            defer outcome.deinit(app.alloc);
            debug_trace.logf("clipboard", "clipboard reply outcome={s}", .{@tagName(outcome)});
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
    };
}
