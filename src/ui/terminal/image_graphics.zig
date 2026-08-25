const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const image_dimensions = @import("../../core/images/image_dimensions.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const terminal_diff = @import("../render_engine/terminal_diff.zig");
const ui_terminal = @import("terminal.zig");
const image_types = @import("image_types.zig");
const terminal_image_codec = @import("terminal_image_codec");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub const default_max_live_images: usize = 8;
const max_kitty_id: u32 = 0x00ff_ffff;
const kitty_raw_chunk_bytes: usize = 3 * 1024;

pub const DetectionValues = struct {
    override: ?[]const u8 = null,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    kitty_window_id: ?[]const u8 = null,
    ghostty_resources_dir: ?[]const u8 = null,
    wezterm_executable: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
    sty: ?[]const u8 = null,
    zellij: ?[]const u8 = null,
};

pub const Capabilities = struct {
    protocol: image_types.Protocol = .none,
    tmux_passthrough: bool = false,
    cells: image_types.CellDimensions = .{},

    pub fn previewConfig(self: Capabilities) image_types.PreviewConfig {
        return .{
            .protocol = self.protocol,
            .cells = self.cells,
        };
    }
};

pub fn detectProtocolForValues(values: DetectionValues) Capabilities {
    if (values.override) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (eqlIgnoreCase(value, "kitty")) {
            return .{
                .protocol = .kitty,
                .tmux_passthrough = values.tmux != null,
            };
        }
        if (eqlIgnoreCase(value, "off") or
            eqlIgnoreCase(value, "none") or
            std.mem.eql(u8, value, "0") or
            eqlIgnoreCase(value, "false")) return .{};
        // An invalid explicit value is a safe opt-out, not permission to guess.
        return .{};
    }

    if (values.tmux != null or values.sty != null or values.zellij != null) return .{};
    const term = values.term orelse "";
    const term_program = values.term_program orelse "";
    if (values.kitty_window_id != null or
        values.ghostty_resources_dir != null or
        values.wezterm_executable != null or
        containsIgnoreCase(term, "kitty") or
        eqlIgnoreCase(term_program, "kitty") or
        eqlIgnoreCase(term_program, "ghostty") or
        eqlIgnoreCase(term_program, "wezterm"))
    {
        return .{ .protocol = .kitty };
    }
    return .{};
}

pub fn detectCapabilities() Capabilities {
    if (comptime builtin.os.tag == .wasi) return .{};
    if (std.c.isatty(std.posix.STDOUT_FILENO) == 0) return .{};

    var result = detectProtocolForValues(.{
        .override = io_mod.getenv("FX_IMAGE_PROTOCOL"),
        .term = io_mod.getenv("TERM"),
        .term_program = io_mod.getenv("TERM_PROGRAM"),
        .kitty_window_id = io_mod.getenv("KITTY_WINDOW_ID"),
        .ghostty_resources_dir = io_mod.getenv("GHOSTTY_RESOURCES_DIR"),
        .wezterm_executable = io_mod.getenv("WEZTERM_EXECUTABLE"),
        .tmux = io_mod.getenv("TMUX"),
        .sty = io_mod.getenv("STY"),
        .zellij = io_mod.getenv("ZELLIJ"),
    });
    result.cells = ui_terminal.queryCellDimensions(std.posix.STDOUT_FILENO) orelse .{};
    return result;
}

pub fn detectedPreviewConfig() image_types.PreviewConfig {
    return detectCapabilities().previewConfig();
}

const ResourceKey = struct {
    source_namespace: usize,
    entry_id: u32,
    attachment_id: usize,
    digest: [32]u8,
};

const Resource = struct {
    key: ResourceKey,
    image_id: u32,
    row: u16,
    col: u16,
    columns: u16,
    rows: u16,

    fn sameRect(self: Resource, placement: image_types.Placement) bool {
        return self.row == placement.row and
            self.col == placement.col and
            self.columns == placement.columns and
            self.rows == placement.rows;
    }
};

const PlannedResource = struct {
    resource: Resource,
    place: bool,
};

pub const CommitOutcome = enum {
    committed,
    failed,
};

pub const Runtime = struct {
    capabilities: Capabilities = .{},
    max_live_images: usize = default_max_live_images,
    next_image_id: u32 = 1,
    resources: std.ArrayList(Resource) = .empty,
    uncertain_ids: std.ArrayList(u32) = .empty,
    desynchronized: bool = false,

    pub fn initDetected() Runtime {
        var seed: u32 = 1;
        if (comptime builtin.os.tag != .wasi) {
            io_mod.getIo().random(std.mem.asBytes(&seed));
        }
        seed &= max_kitty_id;
        if (seed == 0) seed = 1;
        return .{
            .capabilities = detectCapabilities(),
            .next_image_id = seed,
        };
    }

    pub fn initForTest(capabilities: Capabilities, first_image_id: u32) Runtime {
        return .{
            .capabilities = capabilities,
            .next_image_id = normalizeImageId(first_image_id),
        };
    }

    pub fn previewConfig(self: Runtime) image_types.PreviewConfig {
        return self.capabilities.previewConfig();
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.resources.deinit(alloc);
        self.uncertain_ids.deinit(alloc);
        self.* = undefined;
    }

    pub fn invalidatePlacements(self: *Runtime) void {
        if (self.resources.items.len == 0) return;
        self.desynchronized = true;
    }

    pub fn commitFrame(
        self: *Runtime,
        alloc: Allocator,
        placements: []const image_types.Placement,
        synchronized_update: bool,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
        terminal_reset: bool,
        sink: terminal_diff.FrameSink,
        metrics: *Metrics,
    ) !CommitOutcome {
        if (self.capabilities.protocol == .none) return .committed;

        const reset_resources = terminal_reset or self.desynchronized;
        var transmits: std.Io.Writer.Allocating = .init(alloc);
        defer transmits.deinit();
        var planned: std.ArrayList(PlannedResource) = .empty;
        defer planned.deinit(alloc);
        var next_resources: std.ArrayList(Resource) = .empty;
        errdefer next_resources.deinit(alloc);

        const live_start = if (self.max_live_images > 0 and placements.len > self.max_live_images)
            placements.len - self.max_live_images
        else
            0;
        const preview_config = self.previewConfig();
        for (placements[live_start..]) |placement| {
            if (!self.capabilities.protocol.supportsMediaType(placement.attachment.media_type)) continue;
            const key = resourceKey(placement) orelse continue;
            const existing = findResource(self.resources.items, key);
            var image_id: u32 = undefined;
            const needs_transmit = reset_resources or existing == null;
            if (needs_transmit) {
                var snapshot = image_attachments.loadVerifiedSnapshot(
                    alloc,
                    placement.attachment,
                    .{},
                ) catch |err| {
                    debug_trace.logf(
                        "images",
                        "event=terminal_image_snapshot_unavailable image_id={d} err={s}",
                        .{ placement.attachment.id, @errorName(err) },
                    );
                    continue;
                };
                defer snapshot.deinit(alloc);
                var converted_png: ?[]u8 = null;
                defer if (converted_png) |bytes| alloc.free(bytes);
                const payload = if (std.mem.eql(u8, snapshot.media_type, "image/png"))
                    snapshot.bytes
                else blk: {
                    const dimensions = image_dimensions.detect(
                        snapshot.bytes,
                        snapshot.media_type,
                    ) orelse {
                        debug_trace.logf(
                            "images",
                            "event=terminal_image_conversion_failed image_id={d} media_type={s} err=InvalidImageDimensions",
                            .{ placement.attachment.id, snapshot.media_type },
                        );
                        continue;
                    };
                    const bytes = terminal_image_codec.convertToPng(
                        alloc,
                        snapshot.bytes,
                        snapshot.media_type,
                        .{ .width = dimensions.width, .height = dimensions.height },
                        .{
                            .width = @as(u32, placement.columns) *
                                @as(u32, preview_config.cells.width_px),
                            .height = @as(u32, placement.rows) *
                                @as(u32, preview_config.cells.height_px),
                        },
                    ) catch |err| {
                        debug_trace.logf(
                            "images",
                            "event=terminal_image_conversion_failed image_id={d} media_type={s} err={s}",
                            .{ placement.attachment.id, snapshot.media_type, @errorName(err) },
                        );
                        continue;
                    };
                    converted_png = bytes;
                    break :blk bytes;
                };
                image_id = if (existing) |resource| resource.image_id else self.allocateImageId();
                try writeKittyTransmit(
                    &transmits.writer,
                    payload,
                    image_id,
                    self.capabilities.tmux_passthrough,
                );
            } else {
                image_id = existing.?.image_id;
            }

            const resource = Resource{
                .key = key,
                .image_id = image_id,
                .row = placement.row,
                .col = placement.col,
                .columns = placement.columns,
                .rows = placement.rows,
            };
            try next_resources.append(alloc, resource);
            try planned.append(alloc, .{
                .resource = resource,
                .place = reset_resources or existing == null or !existing.?.sameRect(placement),
            });
        }

        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        if (reset_resources) {
            for (self.resources.items) |resource| {
                try writeKittyDelete(&body.writer, resource.image_id, self.capabilities.tmux_passthrough);
            }
            for (self.uncertain_ids.items) |image_id| {
                if (!resourceIdPresent(self.resources.items, image_id)) {
                    try writeKittyDelete(&body.writer, image_id, self.capabilities.tmux_passthrough);
                }
            }
        } else {
            for (self.resources.items) |resource| {
                if (findResource(next_resources.items, resource.key) == null) {
                    try writeKittyDelete(&body.writer, resource.image_id, self.capabilities.tmux_passthrough);
                }
            }
        }
        try body.writer.writeAll(transmits.written());
        for (planned.items) |item| {
            if (!item.place) continue;
            try writeCursorPosition(&body.writer, item.resource.row, item.resource.col);
            try writeKittyPlacement(
                &body.writer,
                item.resource,
                self.capabilities.tmux_passthrough,
            );
        }

        if (body.written().len == 0) {
            self.resources.deinit(alloc);
            self.resources = next_resources;
            next_resources = .empty;
            self.uncertain_ids.clearRetainingCapacity();
            self.desynchronized = false;
            return .committed;
        }

        var wire: std.Io.Writer.Allocating = .init(alloc);
        defer wire.deinit();
        if (synchronized_update) try wire.writer.writeAll("\x1b[?2026h");
        try wire.writer.writeAll("\x1b[?25l");
        try wire.writer.writeAll(body.written());
        try writeCursorPosition(&wire.writer, cursor_row, cursor_col);
        if (synchronized_update) try wire.writer.writeAll("\x1b[?2026l");
        if (cursor_visible) try wire.writer.writeAll("\x1b[?25h");

        // Reserve recovery bookkeeping before the consequential write. A partial
        // sink result must never discover that it cannot remember an uncertain id.
        try self.uncertain_ids.ensureTotalCapacity(
            alloc,
            self.uncertain_ids.items.len + self.resources.items.len + next_resources.items.len,
        );
        const result = sink.write_frame(sink.ctx, metrics, wire.written());
        switch (result) {
            .complete => {
                self.resources.deinit(alloc);
                self.resources = next_resources;
                next_resources = .empty;
                self.uncertain_ids.clearRetainingCapacity();
                self.desynchronized = false;
                return .committed;
            },
            .partial => |partial| {
                if (partial.accepted_bytes > wire.written().len) return error.InvalidFrameSinkProgress;
                try self.rememberUncertainIds(alloc, next_resources.items);
                self.desynchronized = true;
                writeSidecarRecovery(
                    sink,
                    metrics,
                    synchronized_update,
                    cursor_row,
                    cursor_col,
                    cursor_visible,
                );
                debug_trace.logf(
                    "images",
                    "event=terminal_image_partial_write accepted_bytes={d} bytes={d} err={s}",
                    .{ partial.accepted_bytes, wire.written().len, @errorName(partial.err) },
                );
                next_resources.deinit(alloc);
                return .failed;
            },
        }
    }

    pub fn clear(
        self: *Runtime,
        alloc: Allocator,
        sink: terminal_diff.FrameSink,
        metrics: *Metrics,
    ) void {
        if (self.resources.items.len == 0 and self.uncertain_ids.items.len == 0) return;
        var wire: std.Io.Writer.Allocating = .init(alloc);
        defer wire.deinit();
        for (self.resources.items) |resource| {
            writeKittyDelete(&wire.writer, resource.image_id, self.capabilities.tmux_passthrough) catch return;
        }
        for (self.uncertain_ids.items) |image_id| {
            if (!resourceIdPresent(self.resources.items, image_id)) {
                writeKittyDelete(&wire.writer, image_id, self.capabilities.tmux_passthrough) catch return;
            }
        }
        switch (sink.write_frame(sink.ctx, metrics, wire.written())) {
            .complete => {
                self.resources.clearRetainingCapacity();
                self.uncertain_ids.clearRetainingCapacity();
                self.desynchronized = false;
            },
            .partial => {},
        }
    }

    fn allocateImageId(self: *Runtime) u32 {
        const current = normalizeImageId(self.next_image_id);
        self.next_image_id = normalizeImageId(current +% 1);
        return current;
    }

    fn rememberUncertainIds(self: *Runtime, alloc: Allocator, next: []const Resource) !void {
        for (self.resources.items) |resource| try appendUniqueId(&self.uncertain_ids, alloc, resource.image_id);
        for (next) |resource| try appendUniqueId(&self.uncertain_ids, alloc, resource.image_id);
    }
};

fn resourceKey(placement: image_types.Placement) ?ResourceKey {
    const digest_text = placement.attachment.snapshot_sha256 orelse return null;
    if (digest_text.len != 64) return null;
    var digest: [32]u8 = undefined;
    for (0..digest.len) |index| {
        const high = hexNibble(digest_text[index * 2]) orelse return null;
        const low = hexNibble(digest_text[index * 2 + 1]) orelse return null;
        digest[index] = (high << 4) | low;
    }
    return .{
        .source_namespace = placement.source_namespace,
        .entry_id = placement.entry_id,
        .attachment_id = placement.attachment.id,
        .digest = digest,
    };
}

fn findResource(resources: []const Resource, key: ResourceKey) ?Resource {
    for (resources) |resource| {
        if (std.meta.eql(resource.key, key)) return resource;
    }
    return null;
}

fn resourceIdPresent(resources: []const Resource, image_id: u32) bool {
    for (resources) |resource| {
        if (resource.image_id == image_id) return true;
    }
    return false;
}

fn appendUniqueId(ids: *std.ArrayList(u32), alloc: Allocator, image_id: u32) !void {
    for (ids.items) |existing| {
        if (existing == image_id) return;
    }
    try ids.append(alloc, image_id);
}

fn writeKittyTransmit(
    writer: *std.Io.Writer,
    bytes: []const u8,
    image_id: u32,
    tmux_passthrough: bool,
) !void {
    if (bytes.len == 0) return;
    var offset: usize = 0;
    var first = true;
    while (offset < bytes.len) {
        const end = @min(offset + kitty_raw_chunk_bytes, bytes.len);
        var encoded_buffer: [kitty_raw_chunk_bytes / 3 * 4]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, bytes[offset..end]);
        var params_buffer: [96]u8 = undefined;
        const params = if (first)
            try std.fmt.bufPrint(
                &params_buffer,
                "a=t,f=100,q=2,i={d},m={d}",
                .{ image_id, @intFromBool(end < bytes.len) },
            )
        else
            try std.fmt.bufPrint(
                &params_buffer,
                "q=2,m={d}",
                .{@intFromBool(end < bytes.len)},
            );
        try writeKittyCommand(writer, params, encoded, tmux_passthrough);
        first = false;
        offset = end;
    }
}

fn writeKittyPlacement(writer: *std.Io.Writer, resource: Resource, tmux_passthrough: bool) !void {
    var params_buffer: [128]u8 = undefined;
    const params = try std.fmt.bufPrint(
        &params_buffer,
        "a=p,q=2,C=1,i={d},p={d},c={d},r={d}",
        .{ resource.image_id, resource.image_id, resource.columns, resource.rows },
    );
    try writeKittyCommand(writer, params, "", tmux_passthrough);
}

fn writeKittyDelete(writer: *std.Io.Writer, image_id: u32, tmux_passthrough: bool) !void {
    var params_buffer: [64]u8 = undefined;
    const params = try std.fmt.bufPrint(
        &params_buffer,
        "a=d,d=I,i={d},q=2",
        .{image_id},
    );
    try writeKittyCommand(writer, params, "", tmux_passthrough);
}

fn writeKittyCommand(
    writer: *std.Io.Writer,
    params: []const u8,
    payload: []const u8,
    tmux_passthrough: bool,
) !void {
    if (tmux_passthrough) {
        try writer.writeAll("\x1bPtmux;\x1b\x1b_G");
        try writer.writeAll(params);
        if (payload.len > 0) {
            try writer.writeByte(';');
            try writer.writeAll(payload);
        }
        try writer.writeAll("\x1b\x1b\\\x1b\\");
        return;
    }
    try writer.writeAll("\x1b_G");
    try writer.writeAll(params);
    if (payload.len > 0) {
        try writer.writeByte(';');
        try writer.writeAll(payload);
    }
    try writer.writeAll("\x1b\\");
}

fn writeCursorPosition(writer: *std.Io.Writer, row: u16, col: u16) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

fn writeSidecarRecovery(
    sink: terminal_diff.FrameSink,
    metrics: *Metrics,
    synchronized_update: bool,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
) void {
    var buffer: [96]u8 = undefined;
    const bytes = std.fmt.bufPrint(
        &buffer,
        "\x18\x1b\\{s}\x1b[{d};{d}H{s}",
        .{
            if (synchronized_update) "\x1b[?2026l" else "",
            cursor_row,
            cursor_col,
            if (cursor_visible) "\x1b[?25h" else "",
        },
    ) catch return;
    _ = sink.write_frame(sink.ctx, metrics, bytes);
}

fn normalizeImageId(value: u32) u32 {
    const masked = value & max_kitty_id;
    return if (masked == 0) 1 else masked;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

const TestSink = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    partial_once: bool = false,

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(self.alloc);
    }

    fn clear(self: *TestSink) void {
        self.bytes.clearRetainingCapacity();
        self.calls = 0;
    }

    fn sink(self: *TestSink) terminal_diff.FrameSink {
        return .{ .ctx = self, .write_frame = write };
    }

    fn write(raw: *anyopaque, metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
        const self: *TestSink = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.partial_once) {
            self.partial_once = false;
            const accepted = @min(bytes.len, 5);
            self.bytes.appendSlice(self.alloc, bytes[0..accepted]) catch return .{ .partial = .{
                .accepted_bytes = 0,
                .err = error.OutOfMemory,
            } };
            metrics.ansi_bytes += accepted;
            return .{ .partial = .{
                .accepted_bytes = accepted,
                .err = error.TestPartialWrite,
            } };
        }
        self.bytes.appendSlice(self.alloc, bytes) catch return .{ .partial = .{
            .accepted_bytes = 0,
            .err = error.OutOfMemory,
        } };
        metrics.ansi_bytes += bytes.len;
        return .complete;
    }
};

test "Kitty runtime transmits once, moves stably, and deletes stale images" {
    const alloc = std.testing.allocator;
    const png_bytes = "\x89PNG\r\n\x1a\nminimal-test-payload";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "snapshot.png", .{});
    try file.writeStreamingAll(std.testing.io, png_bytes);
    file.close(std.testing.io);
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.png");
    defer alloc.free(snapshot_path);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png_bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    const attachment = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/original.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = digest_hex[0..],
        .pixel_width = 1,
        .pixel_height = 1,
    };
    const placement = image_types.Placement{
        .source_namespace = 77,
        .entry_id = 9,
        .attachment = attachment,
        .row = 2,
        .col = 3,
        .columns = 4,
        .rows = 2,
    };

    var runtime = Runtime.initForTest(.{ .protocol = .kitty }, 42);
    defer runtime.deinit(alloc);
    var sink = TestSink{ .alloc = alloc };
    defer sink.deinit();
    var metrics: Metrics = .{};

    try std.testing.expectEqual(
        CommitOutcome.committed,
        try runtime.commitFrame(alloc, &.{placement}, true, 12, 5, true, false, sink.sink(), &metrics),
    );
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=t,f=100,q=2,i=42") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=p,q=2,C=1,i=42,p=42,c=4,r=2") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "iVBOR") != null);

    sink.clear();
    _ = try runtime.commitFrame(alloc, &.{placement}, true, 12, 5, true, false, sink.sink(), &metrics);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);

    sink.clear();
    var moved = placement;
    moved.row = 4;
    _ = try runtime.commitFrame(alloc, &.{moved}, false, 12, 5, true, false, sink.sink(), &metrics);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=p,q=2,C=1,i=42") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=t,f=100") == null);

    sink.clear();
    _ = try runtime.commitFrame(alloc, &.{}, false, 12, 5, true, false, sink.sink(), &metrics);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=d,d=I,i=42,q=2") != null);
}

test "Kitty runtime converts JPEG snapshots to PNG before transmission" {
    const alloc = std.testing.allocator;
    const jpeg_bytes = @embedFile("testdata/red-2x3.jpg");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "snapshot.jpg", .{});
    try file.writeStreamingAll(std.testing.io, jpeg_bytes);
    file.close(std.testing.io);
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.jpg");
    defer alloc.free(snapshot_path);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(jpeg_bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    const attachment = types.ImageAttachment{
        .id = 2,
        .path = @constCast("/tmp/original.jpg"),
        .media_type = @constCast("image/jpeg"),
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = digest_hex[0..],
        .pixel_width = 2,
        .pixel_height = 3,
    };
    const placement = image_types.Placement{
        .source_namespace = 91,
        .entry_id = 4,
        .attachment = attachment,
        .row = 1,
        .col = 1,
        .columns = 2,
        .rows = 1,
    };

    var runtime = Runtime.initForTest(.{
        .protocol = .kitty,
        .cells = .{ .width_px = 8, .height_px = 16 },
    }, 55);
    defer runtime.deinit(alloc);
    var sink = TestSink{ .alloc = alloc };
    defer sink.deinit();
    var metrics: Metrics = .{};

    try std.testing.expectEqual(
        CommitOutcome.committed,
        try runtime.commitFrame(alloc, &.{placement}, false, 1, 1, true, false, sink.sink(), &metrics),
    );
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=t,f=100,q=2,i=55") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "iVBOR") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "/9j/") == null);
}

test "Kitty runtime repairs an uncertain partial sidecar write" {
    const alloc = std.testing.allocator;
    const png_bytes = "\x89PNG\r\n\x1a\npartial-test-payload";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "snapshot.png", .{});
    try file.writeStreamingAll(std.testing.io, png_bytes);
    file.close(std.testing.io);
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.png");
    defer alloc.free(snapshot_path);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png_bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    const attachment = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/original.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = digest_hex[0..],
    };
    const placement = image_types.Placement{
        .source_namespace = 1,
        .entry_id = 1,
        .attachment = attachment,
        .row = 1,
        .col = 3,
        .columns = 2,
        .rows = 1,
    };
    var runtime = Runtime.initForTest(.{ .protocol = .kitty }, 7);
    defer runtime.deinit(alloc);
    var sink = TestSink{ .alloc = alloc, .partial_once = true };
    defer sink.deinit();
    var metrics: Metrics = .{};

    try std.testing.expectEqual(
        CommitOutcome.failed,
        try runtime.commitFrame(alloc, &.{placement}, false, 2, 1, true, false, sink.sink(), &metrics),
    );
    sink.clear();
    try std.testing.expectEqual(
        CommitOutcome.committed,
        try runtime.commitFrame(alloc, &.{placement}, false, 2, 1, true, false, sink.sink(), &metrics),
    );
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=d,d=I,i=7,q=2") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=t,f=100,q=2,i=8") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "a=p,q=2,C=1,i=8,p=8") != null);
}

test "automatic Kitty detection is conservative around multiplexers" {
    try std.testing.expectEqual(
        image_types.Protocol.kitty,
        detectProtocolForValues(.{ .term_program = "ghostty" }).protocol,
    );
    try std.testing.expectEqual(
        image_types.Protocol.kitty,
        detectProtocolForValues(.{ .wezterm_executable = "/Applications/WezTerm" }).protocol,
    );
    try std.testing.expectEqual(
        image_types.Protocol.none,
        detectProtocolForValues(.{ .term = "xterm-kitty", .tmux = "/tmp/tmux" }).protocol,
    );
    const forced = detectProtocolForValues(.{ .override = "kitty", .tmux = "/tmp/tmux" });
    try std.testing.expectEqual(image_types.Protocol.kitty, forced.protocol);
    try std.testing.expect(forced.tmux_passthrough);
}

test "Kitty commands use quiet chunking and tmux passthrough" {
    const alloc = std.testing.allocator;
    var direct: std.Io.Writer.Allocating = .init(alloc);
    defer direct.deinit();
    try writeKittyTransmit(&direct.writer, "abc", 9, false);
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,f=100,q=2,i=9,m=0;YWJj\x1b\\",
        direct.written(),
    );

    var tmux: std.Io.Writer.Allocating = .init(alloc);
    defer tmux.deinit();
    try writeKittyDelete(&tmux.writer, 9, true);
    try std.testing.expectEqualStrings(
        "\x1bPtmux;\x1b\x1b_Ga=d,d=I,i=9,q=2\x1b\x1b\\\x1b\\",
        tmux.written(),
    );
}
