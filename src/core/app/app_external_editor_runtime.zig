const std = @import("std");
const host = @import("../hosts/host.zig");
const types = @import("../shared/types.zig");
const input_runtime = @import("../input/runtime.zig");
const render_request = @import("../../ui/render_request.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn editComposer(
            app: *App,
            editor: host.ExternalEditor,
            max_bytes: usize,
        ) !bool {
            if (structuredDraft(app)) {
                try writeNotice(
                    app,
                    .warning,
                    "external editing is unavailable while the draft contains pasted blocks, images, or skills",
                );
                return false;
            }

            const seed = app.input_runtime.edit_state.input.items;
            var result = try app.runExternalInteractive(editor, seed, max_bytes);
            defer result.deinit(app.alloc);
            switch (result) {
                .edited => |text| {
                    const normalized = normalizeFinalNewline(seed, text);
                    if (std.mem.eql(u8, seed, normalized)) return false;
                    try app.input_runtime.textReplacementState().replace(app.alloc, normalized);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .canceled => return false,
                .failed => |failure| {
                    try reportFailure(app, failure);
                    return false;
                },
            }
        }

        fn structuredDraft(app: *const App) bool {
            return app.input_runtime.entities.pasted_blocks.items.len > 0 or
                app.input_runtime.entities.image_tokens.items.len > 0 or
                app.input_runtime.entities.skill_tokens.items.len > 0 or
                app.pending_images.items.len > 0;
        }

        fn reportFailure(app: *App, failure: host.ExternalEditor.Failure) !void {
            const summary = switch (failure.reason) {
                .unavailable => "external editing is unavailable on this host",
                .missing_editor => "set VISUAL or EDITOR to use Ctrl+T",
                .invalid_command => "VISUAL or EDITOR must name an executable and arguments without shell operators",
                .editor_failed => "the external editor failed",
                .output_invalid => "the external editor returned invalid text",
                .output_too_large => "the external editor output exceeded the composer limit",
            };
            if (failure.kept_path) |path| {
                const body = try std.fmt.allocPrint(
                    app.alloc,
                    "{s}; your saved draft is at {s}",
                    .{ summary, path },
                );
                defer app.alloc.free(body);
                try writeNotice(app, .@"error", body);
                return;
            }
            try writeNotice(
                app,
                switch (failure.reason) {
                    .unavailable, .missing_editor => .warning,
                    else => .@"error",
                },
                summary,
            );
        }

        fn writeNotice(app: *App, tone: types.NoticeTone, body: []const u8) !void {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = tone,
                .body = body,
            }, true);
            app.shell.render_requests.request(.footer);
        }
    };
}

fn normalizeFinalNewline(seed: []const u8, edited: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, seed, "\n") and std.mem.endsWith(u8, edited, "\n")) {
        return edited[0 .. edited.len - 1];
    }
    return edited;
}

test "external editor normalization removes only an editor-added final newline" {
    try std.testing.expectEqualStrings("edited", normalizeFinalNewline("seed", "edited\n"));
    try std.testing.expectEqualStrings("edited\n", normalizeFinalNewline("seed\n", "edited\n"));
    try std.testing.expectEqualStrings("edited\n\n", normalizeFinalNewline("seed\n", "edited\n\n"));
}

const TestResult = union(enum) {
    edited: []const u8,
    canceled,
    failed: host.ExternalEditor.Failure,
};

const TestShell = struct {
    render_requests: render_request.RenderRequestState = .{},
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: input_runtime.Runtime = .{},
    pending_images: std.ArrayList(u8) = .empty,
    shell: TestShell = .{},
    next_result: TestResult = .canceled,
    run_count: usize = 0,
    max_bytes_seen: usize = 0,
    notice_body: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
    }

    pub fn runExternalInteractive(
        self: *TestApp,
        _: host.ExternalEditor,
        _: []const u8,
        max_bytes: usize,
    ) !host.ExternalEditor.EditResult {
        self.run_count += 1;
        self.max_bytes_seen = max_bytes;
        return switch (self.next_result) {
            .edited => |text| .{ .edited = try self.alloc.dupe(u8, text) },
            .canceled => .canceled,
            .failed => |failure| .{ .failed = .{
                .reason = failure.reason,
                .kept_path = if (failure.kept_path) |path|
                    try self.alloc.dupe(u8, path)
                else
                    null,
            } },
        };
    }

    pub fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_body.clearRetainingCapacity();
        try self.notice_body.appendSlice(self.alloc, notice.body);
    }
};

test "external editor replaces a plain draft and preserves a normalized no-op" {
    const alloc = std.testing.allocator;
    var app = TestApp{ .alloc = alloc, .next_result = .{ .edited = "edited\n" } };
    defer app.deinit();
    try app.input_runtime.edit_state.setText(alloc, "seed");

    try std.testing.expect(try Runtime(TestApp).editComposer(
        &app,
        host.unavailable_external_editor,
        1234,
    ));
    try std.testing.expectEqualStrings("edited", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 1234), app.max_bytes_seen);

    _ = app.input_runtime.edit_state.setCursor(2);
    app.next_result = .{ .edited = "edited\n" };
    try std.testing.expect(!try Runtime(TestApp).editComposer(
        &app,
        host.unavailable_external_editor,
        1234,
    ));
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.edit_state.cursor);
}

test "external editor refuses structured drafts before terminal handoff" {
    const alloc = std.testing.allocator;
    var app = TestApp{ .alloc = alloc, .next_result = .{ .edited = "changed" } };
    defer app.deinit();
    try app.input_runtime.edit_state.setText(alloc, "[Image #1]");
    try app.input_runtime.entities.image_tokens.append(alloc, .{
        .id = 1,
        .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len },
    });

    try std.testing.expect(!try Runtime(TestApp).editComposer(
        &app,
        host.unavailable_external_editor,
        1234,
    ));
    try std.testing.expectEqual(@as(usize, 0), app.run_count);
    try std.testing.expect(std.mem.find(u8, app.notice_body.items, "pasted blocks, images, or skills") != null);
}

test "external editor reports the recovery path for unusable output" {
    const alloc = std.testing.allocator;
    var app = TestApp{
        .alloc = alloc,
        .next_result = .{ .failed = .{
            .reason = .output_too_large,
            .kept_path = @constCast("/tmp/recovered.md"),
        } },
    };
    defer app.deinit();

    try std.testing.expect(!try Runtime(TestApp).editComposer(
        &app,
        host.unavailable_external_editor,
        1234,
    ));
    try std.testing.expect(std.mem.find(u8, app.notice_body.items, "composer limit") != null);
    try std.testing.expect(std.mem.find(u8, app.notice_body.items, "/tmp/recovered.md") != null);
}
