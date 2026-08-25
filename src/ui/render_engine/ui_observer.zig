//! Opt-in terminal UI frame observer for deterministic local diagnosis.
//!
//! This module never writes terminal bytes. When `FX_UI_OBSERVE_DIR` is set
//! to an absolute local directory, it writes committed frame sidecars and
//! honors a one-shot file latch used by the tmux scenario runner.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const record_tape = @import("../../core/workspace/record_tape.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const transcript_blocks = @import("transcript_blocks.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

const ObserverState = enum {
    unknown,
    disabled,
    enabled,
};

const ArmKind = enum {
    normal,
    alternate_screen,
};

const ActivityKind = enum {
    none,
    turn_thinking,
    tool_slot,
};

const Arm = struct {
    bytes: []u8,
    kind: ArmKind,
    scenario: []const u8,
    checkpoint: []const u8,
    sequence_floor: u64,
    activity_kind: ?ActivityKind = null,
    stream_active: ?bool = null,
    completed_assistant_presentation_tail: ?bool = null,
    contains: ?[]const u8 = null,

    fn deinit(self: *Arm, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const NormalFrameInput = struct {
    surface: *const frame_surface.FrameSurface,
    plan: *const paint_plan.PaintPlan,
    row_provenance: []const transcript_blocks.RowProvenance,
    activity: activity_runtime.ActivityProjection,
    stream_active: bool,
    completed_assistant_presentation_tail: bool,
};

pub const AlternateScreenInput = struct {
    request_id: u64,
    rows: u16,
    cols: u16,
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
};

pub const UiObserver = struct {
    state: ObserverState = .unknown,
    root: []u8 = &.{},
    frames_file: ?std.Io.File = null,
    next_sequence: u64 = 0,
    selected: bool = false,

    pub fn enabled(self: *UiObserver, alloc: Allocator) bool {
        self.ensureConfigured(alloc);
        return self.state == .enabled;
    }

    pub fn deinit(self: *UiObserver, alloc: Allocator) void {
        if (self.frames_file) |*file| file.close(io_mod.getIo());
        if (self.root.len > 0) alloc.free(self.root);
        self.* = .{};
    }

    pub fn observeNormalFrame(
        self: *UiObserver,
        alloc: Allocator,
        input: NormalFrameInput,
    ) void {
        if (!self.enabled(alloc)) return;

        self.next_sequence += 1;
        const sequence = self.next_sequence;
        self.writeNormalRecord(alloc, sequence, input) catch |err| {
            self.disableAfterError(alloc, "normal_frame", err);
            return;
        };
        self.selectIfArmed(alloc, sequence, .normal, input) catch |err| {
            self.disableAfterError(alloc, "normal_latch", err);
        };
    }

    pub fn observeAlternateScreen(
        self: *UiObserver,
        alloc: Allocator,
        input: AlternateScreenInput,
    ) void {
        if (!self.enabled(alloc)) return;

        self.next_sequence += 1;
        const sequence = self.next_sequence;
        self.writeAlternateScreenRecord(alloc, sequence, input) catch |err| {
            self.disableAfterError(alloc, "alternate_screen", err);
            return;
        };
        self.selectAlternateIfArmed(alloc, sequence, input) catch |err| {
            self.disableAfterError(alloc, "alternate_latch", err);
        };
    }

    fn ensureConfigured(self: *UiObserver, alloc: Allocator) void {
        if (self.state != .unknown) return;

        const raw_root = io_mod.getenv("FX_UI_OBSERVE_DIR") orelse {
            self.state = .disabled;
            return;
        };
        const root = std.mem.trim(u8, raw_root, " \t\r\n");
        if (root.len == 0 or !std.fs.path.isAbsolute(root)) {
            self.state = .disabled;
            debug_trace.logf(
                "ui_observer",
                "disabled invalid_observe_dir absolute_required={s}",
                .{if (std.fs.path.isAbsolute(root)) "false" else "true"},
            );
            return;
        }

        io_mod.makeDirRecursive(root) catch |err| {
            self.state = .disabled;
            debug_trace.logf(
                "ui_observer",
                "disabled mkdir err={s}",
                .{@errorName(err)},
            );
            return;
        };
        const frames_path = std.fs.path.join(alloc, &.{ root, "frames.jsonl" }) catch |err| {
            self.state = .disabled;
            debug_trace.logf(
                "ui_observer",
                "disabled frames_path err={s}",
                .{@errorName(err)},
            );
            return;
        };
        defer alloc.free(frames_path);
        const file = std.Io.Dir.createFileAbsolute(
            io_mod.getIo(),
            frames_path,
            .{ .truncate = true },
        ) catch |err| {
            self.state = .disabled;
            debug_trace.logf(
                "ui_observer",
                "disabled frames_open err={s}",
                .{@errorName(err)},
            );
            return;
        };
        const owned_root = alloc.dupe(u8, root) catch |err| {
            file.close(io_mod.getIo());
            self.state = .disabled;
            debug_trace.logf(
                "ui_observer",
                "disabled root_alloc err={s}",
                .{@errorName(err)},
            );
            return;
        };

        self.root = owned_root;
        self.frames_file = file;
        self.state = .enabled;
        debug_trace.logf("ui_observer", "enabled", .{});
    }

    fn disableAfterError(
        self: *UiObserver,
        alloc: Allocator,
        operation: []const u8,
        err: anyerror,
    ) void {
        debug_trace.logf(
            "ui_observer",
            "disabled operation={s} err={s}",
            .{ operation, @errorName(err) },
        );
        self.deinit(alloc);
        self.state = .disabled;
    }

    fn writeNormalRecord(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        input: NormalFrameInput,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print(
            "{{\"sequence\":{d},\"kind\":\"normal_frame\",\"rows\":{d},\"cols\":{d},\"bands\":{{\"transcript\":[{d},{d}],\"activity\":[{d},{d}],\"footer\":[{d},{d}]}},\"activity\":",
            .{
                sequence,
                input.surface.rows,
                input.surface.cols,
                input.plan.transcript_band.top,
                input.plan.transcript_band.bottom,
                input.plan.activity_band.top,
                input.plan.activity_band.bottom,
                input.plan.footer_band.top,
                input.plan.footer_band.bottom,
            },
        );
        try writeActivityJson(&out.writer, input.activity);
        try out.writer.print(
            ",\"stream_active\":{s},\"completed_assistant_presentation_tail\":{s},\"visible_rows\":[",
            .{
                if (input.stream_active) "true" else "false",
                if (input.completed_assistant_presentation_tail) "true" else "false",
            },
        );

        var rows = try ObservedRowIterator.init(alloc, input);
        defer rows.deinit();
        while (try rows.next()) |observed| {
            if (observed.row > 1) try out.writer.writeByte(',');
            try out.writer.print("{{\"row\":{d},\"owner\":", .{observed.row});
            try std.json.Stringify.value(
                @tagName(observed.owner),
                .{},
                &out.writer,
            );
            try out.writer.writeAll(",\"text\":");
            try std.json.Stringify.value(observed.text, .{}, &out.writer);
            try out.writer.writeAll(",\"provenance\":");
            try writeProvenanceJson(&out.writer, observed.provenance);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}\n");
        try self.writeFrameBytes(out.written(), false);
    }

    fn writeAlternateScreenRecord(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        input: AlternateScreenInput,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print(
            "{{\"sequence\":{d},\"kind\":\"alternate_screen\",\"request_id\":{d},\"rows\":{d},\"cols\":{d},\"file_identity_visible\":{s},\"all_decision_controls_visible\":{s},\"changed_or_notice_visible\":{s},\"document_scrollable\":{s}}}\n",
            .{
                sequence,
                input.request_id,
                input.rows,
                input.cols,
                if (input.file_identity_visible) "true" else "false",
                if (input.all_decision_controls_visible) "true" else "false",
                if (input.changed_or_notice_visible) "true" else "false",
                if (input.document_scrollable) "true" else "false",
            },
        );
        try self.writeFrameBytes(out.written(), false);
    }

    fn writeFrameBytes(self: *UiObserver, bytes: []const u8, sync: bool) !void {
        const file = self.frames_file orelse return error.ObserverNotConfigured;
        try file.writeStreamingAll(io_mod.getIo(), bytes);
        if (sync) try file.sync(io_mod.getIo());
    }

    fn selectIfArmed(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        expected_kind: ArmKind,
        input: NormalFrameInput,
    ) !void {
        var arm = (try self.readArm(alloc)) orelse return;
        defer arm.deinit(alloc);
        if (self.selected or arm.kind != expected_kind or sequence <= arm.sequence_floor) return;
        if (!activityMatches(arm.activity_kind, input.activity)) return;
        if (arm.stream_active) |expected| {
            if (expected != input.stream_active) return;
        }
        if (arm.completed_assistant_presentation_tail) |expected| {
            if (expected != input.completed_assistant_presentation_tail) return;
        }
        if (arm.contains) |needle| {
            if (!try surfaceContainsText(alloc, input.surface, needle)) return;
        }
        self.selected = true;
        try self.writeSelectionArtifacts(alloc, sequence, &arm, input);
    }

    fn selectAlternateIfArmed(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        input: AlternateScreenInput,
    ) !void {
        var arm = (try self.readArm(alloc)) orelse return;
        defer arm.deinit(alloc);
        if (self.selected or arm.kind != .alternate_screen or sequence <= arm.sequence_floor) return;
        self.selected = true;

        var summary: std.Io.Writer.Allocating = .init(alloc);
        defer summary.deinit();
        try summary.writer.print(
            "sequence: {d}\nkind: alternate_screen\nrequest_id: {d}\nrows: {d}\ncols: {d}\nfile_identity_visible: {s}\nall_decision_controls_visible: {s}\nchanged_or_notice_visible: {s}\ndocument_scrollable: {s}\n",
            .{
                sequence,
                input.request_id,
                input.rows,
                input.cols,
                if (input.file_identity_visible) "true" else "false",
                if (input.all_decision_controls_visible) "true" else "false",
                if (input.changed_or_notice_visible) "true" else "false",
                if (input.document_scrollable) "true" else "false",
            },
        );
        try self.writeFrameBytes("", true);
        try self.writeArtifact(alloc, "frame-summary.txt", summary.written());
        try self.writeCheckpointAndWait(alloc, sequence, &arm);
    }

    fn writeSelectionArtifacts(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        arm: *const Arm,
        input: NormalFrameInput,
    ) !void {
        var summary: std.Io.Writer.Allocating = .init(alloc);
        defer summary.deinit();
        try summary.writer.print(
            "sequence: {d}\nkind: normal_frame\nrows: {d}\ncols: {d}\nstream_active: {s}\ncompleted_assistant_presentation_tail: {s}\n",
            .{
                sequence,
                input.surface.rows,
                input.surface.cols,
                if (input.stream_active) "true" else "false",
                if (input.completed_assistant_presentation_tail) "true" else "false",
            },
        );

        var rows = try ObservedRowIterator.init(alloc, input);
        defer rows.deinit();
        while (try rows.next()) |observed| {
            try summary.writer.print(
                "{d: >3} {s}",
                .{ observed.row, @tagName(observed.owner) },
            );
            if (observed.provenance) |source| {
                try summary.writer.writeByte(' ');
                try writeProvenanceSummary(&summary.writer, source);
            }
            if (observed.text.len > 0) {
                try summary.writer.print(" {s}", .{observed.text});
            }
            try summary.writer.writeByte('\n');
        }

        try self.writeFrameBytes("", true);
        try self.writeArtifact(alloc, "frame-summary.txt", summary.written());
        try self.writeCheckpointAndWait(alloc, sequence, arm);
    }

    fn writeCheckpointAndWait(
        self: *UiObserver,
        alloc: Allocator,
        sequence: u64,
        arm: *const Arm,
    ) !void {
        var label: std.Io.Writer.Allocating = .init(alloc);
        defer label.deinit();
        try label.writer.print(
            "ui-observer:{s}:{s}:frame:{d}",
            .{ arm.scenario, arm.checkpoint, sequence },
        );
        record_tape.recordMarker(label.written());

        var checkpoint: std.Io.Writer.Allocating = .init(alloc);
        defer checkpoint.deinit();
        try checkpoint.writer.print(
            "{{\"scenario\":",
            .{},
        );
        try std.json.Stringify.value(arm.scenario, .{}, &checkpoint.writer);
        try checkpoint.writer.writeAll(",\"checkpoint\":");
        try std.json.Stringify.value(arm.checkpoint, .{}, &checkpoint.writer);
        try checkpoint.writer.print(
            ",\"sequence\":{d},\"kind\":",
            .{sequence},
        );
        try std.json.Stringify.value(@tagName(arm.kind), .{}, &checkpoint.writer);
        try checkpoint.writer.writeAll("}\n");
        try self.writeArtifact(alloc, "checkpoint.json", checkpoint.written());

        const release_path = try std.fs.path.join(alloc, &.{ self.root, "release" });
        defer alloc.free(release_path);
        while (true) {
            std.Io.Dir.accessAbsolute(io_mod.getIo(), release_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    io_mod.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    fn writeArtifact(
        self: *UiObserver,
        alloc: Allocator,
        name: []const u8,
        contents: []const u8,
    ) !void {
        const path = try std.fs.path.join(alloc, &.{ self.root, name });
        defer alloc.free(path);
        var file = try std.Io.Dir.createFileAbsolute(
            io_mod.getIo(),
            path,
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), contents);
        try file.sync(io_mod.getIo());
    }

    fn readArm(self: *UiObserver, alloc: Allocator) !?Arm {
        const path = try std.fs.path.join(alloc, &.{ self.root, "arm" });
        defer alloc.free(path);
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(alloc, &file, 16 * 1024);
        errdefer alloc.free(bytes);

        var kind: ?ArmKind = null;
        var scenario: ?[]const u8 = null;
        var checkpoint: ?[]const u8 = null;
        var sequence_floor: ?u64 = null;
        var activity_kind: ?ActivityKind = null;
        var stream_active: ?bool = null;
        var completed_assistant_presentation_tail: ?bool = null;
        var contains: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..separator], " \t\r");
            const value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");
            if (std.mem.eql(u8, key, "kind")) {
                kind = std.meta.stringToEnum(ArmKind, value);
            } else if (std.mem.eql(u8, key, "scenario")) {
                scenario = value;
            } else if (std.mem.eql(u8, key, "checkpoint")) {
                checkpoint = value;
            } else if (std.mem.eql(u8, key, "sequence_floor")) {
                sequence_floor = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.mem.eql(u8, key, "activity_kind")) {
                activity_kind = std.meta.stringToEnum(ActivityKind, value) orelse
                    return error.InvalidObserverArm;
            } else if (std.mem.eql(u8, key, "stream_active")) {
                stream_active = parseArmBool(value) orelse return error.InvalidObserverArm;
            } else if (std.mem.eql(u8, key, "completed_assistant_presentation_tail")) {
                completed_assistant_presentation_tail = parseArmBool(value) orelse return error.InvalidObserverArm;
            } else if (std.mem.eql(u8, key, "contains")) {
                contains = value;
            }
        }
        if (kind == null or scenario == null or checkpoint == null or sequence_floor == null) {
            return error.InvalidObserverArm;
        }
        return .{
            .bytes = bytes,
            .kind = kind.?,
            .scenario = scenario.?,
            .checkpoint = checkpoint.?,
            .sequence_floor = sequence_floor.?,
            .activity_kind = activity_kind,
            .stream_active = stream_active,
            .completed_assistant_presentation_tail = completed_assistant_presentation_tail,
            .contains = contains,
        };
    }
};

fn parseArmBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn activityMatches(
    expected: ?ActivityKind,
    activity: activity_runtime.ActivityProjection,
) bool {
    const expected_kind = expected orelse return true;
    const actual_kind: ActivityKind = switch (activity) {
        .none => .none,
        .turn_thinking => .turn_thinking,
        .tool_slot => .tool_slot,
    };
    return actual_kind == expected_kind;
}

fn surfaceContainsText(
    alloc: Allocator,
    surface: *const frame_surface.FrameSurface,
    needle: []const u8,
) !bool {
    if (needle.len == 0) return true;
    var target = try surface.copyToTargetGrid(alloc);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);

    var row: u16 = 1;
    while (row <= surface.rows) : (row += 1) {
        row_text.clearRetainingCapacity();
        try target.rowText(row, &row_text);
        if (std.mem.indexOf(u8, row_text.items, needle) != null) return true;
    }
    return false;
}

const ObservedOwner = enum {
    preserved_shell,
    transcript,
    activity,
    activity_overlay,
    footer,
    gap,
    diagnostic_clear,
};

const ObservedRow = struct {
    row: u16,
    text: []const u8,
    owner: ObservedOwner,
    provenance: ?transcript_blocks.LineProvenance,
};

/// Shared per-row projection of a committed frame: trimmed row text, observed
/// owner, and provenance with the empty-transcript default applied. The
/// frames.jsonl record and the armed frame summary must describe the same
/// frame identically, so both writers walk rows through this iterator.
const ObservedRowIterator = struct {
    alloc: Allocator,
    surface: *const frame_surface.FrameSurface,
    row_provenance: []const transcript_blocks.RowProvenance,
    target: vt_emulator.Grid,
    row_text: std.ArrayList(u8) = .empty,
    next_row: u16 = 1,

    fn init(alloc: Allocator, input: NormalFrameInput) !ObservedRowIterator {
        return .{
            .alloc = alloc,
            .surface = input.surface,
            .row_provenance = input.row_provenance,
            .target = try input.surface.copyToTargetGrid(alloc),
        };
    }

    fn deinit(self: *ObservedRowIterator) void {
        self.target.deinit();
        self.row_text.deinit(self.alloc);
    }

    /// The returned text slice is valid until the next call.
    fn next(self: *ObservedRowIterator) !?ObservedRow {
        if (self.next_row > self.surface.rows) return null;
        const row = self.next_row;
        self.next_row += 1;

        self.row_text.clearRetainingCapacity();
        try self.target.rowTextTrimmed(row, &self.row_text);
        const raw_provenance = provenanceForRow(self.row_provenance, row);
        const owner = observedOwner(self.surface, row, raw_provenance != null);
        return .{
            .row = row,
            .text = self.row_text.items,
            .owner = owner,
            .provenance = raw_provenance orelse if (owner == .transcript)
                @as(transcript_blocks.LineProvenance, .empty_transcript)
            else
                null,
        };
    }
};

fn observedOwner(
    surface: *const frame_surface.FrameSurface,
    row: u16,
    has_transcript_provenance: bool,
) ObservedOwner {
    var has_transcript = false;
    var has_activity = false;
    var has_footer = false;
    var has_gap = false;
    var has_diagnostic = false;
    var col: u16 = 1;
    while (col <= surface.cols) : (col += 1) {
        const owner = surface.cellAt(row, col).?.owner;
        switch (owner) {
            .diagnostic_clear => has_diagnostic = true,
            .footer => has_footer = true,
            .activity => has_activity = true,
            .gap => has_gap = true,
            .transcript => has_transcript = true,
            .preserved_shell => {},
        }
    }
    if (has_diagnostic) return .diagnostic_clear;
    if (has_footer) return .footer;
    if (has_activity) return if (has_transcript_provenance) .activity_overlay else .activity;
    if (has_gap) return .gap;
    if (has_transcript) return .transcript;
    return .preserved_shell;
}

fn provenanceForRow(
    rows: []const transcript_blocks.RowProvenance,
    row: u16,
) ?transcript_blocks.LineProvenance {
    for (rows) |item| {
        if (item.row == row) return item.source;
    }
    return null;
}

fn writeActivityJson(
    writer: *std.Io.Writer,
    activity: activity_runtime.ActivityProjection,
) !void {
    switch (activity) {
        .none => try writer.writeAll("{\"kind\":\"none\"}"),
        .turn_thinking => |thinking| {
            try writer.writeAll("{\"kind\":\"turn_thinking\",\"label\":");
            try std.json.Stringify.value(thinking.label, .{}, writer);
            try writer.writeByte('}');
        },
        .tool_slot => |tool| {
            try writer.print("{{\"kind\":\"tool_slot\",\"entry_id\":{d},\"active\":{s},\"tool_kind\":", .{
                tool.entry_id,
                if (tool.active) "true" else "false",
            });
            try std.json.Stringify.value(@tagName(tool.kind), .{}, writer);
            try writer.writeAll(",\"fallback_label\":");
            try std.json.Stringify.value(tool.fallback_label, .{}, writer);
            try writer.writeAll(",\"thinking_label\":");
            if (tool.thinking_label) |label| {
                try std.json.Stringify.value(label, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        },
    }
}

fn writeProvenanceJson(
    writer: *std.Io.Writer,
    provenance: ?transcript_blocks.LineProvenance,
) !void {
    const source = provenance orelse {
        try writer.writeAll("null");
        return;
    };
    switch (source) {
        .entry => |entry| {
            try writer.print("{{\"kind\":\"entry\",\"entry_id\":{d},\"entry_class\":", .{entry.entry_id});
            try std.json.Stringify.value(@tagName(entry.entry_class), .{}, writer);
            try writer.writeAll("}");
        },
        .image => |image| try writer.print(
            "{{\"kind\":\"image\",\"entry_id\":{d},\"image_id\":{d},\"row_index\":{d},\"row_count\":{d}}}",
            .{ image.entry_id, image.image_id, image.row_index, image.row_count },
        ),
        .block_separator,
        .boundary_blank,
        .capped_continuation,
        .unattributed,
        .empty_transcript,
        => {
            try writer.writeAll("{\"kind\":");
            try std.json.Stringify.value(@tagName(source), .{}, writer);
            try writer.writeAll("}");
        },
        .folded_command_output => |output| {
            try writer.writeAll("{\"kind\":\"folded_command_output\",\"entry_id\":");
            if (output.entry_id) |entry_id| {
                try writer.print("{d}", .{entry_id});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"stream\":");
            try std.json.Stringify.value(@tagName(output.stream), .{}, writer);
            try writer.writeAll("}");
        },
    }
}

fn writeProvenanceSummary(
    writer: *std.Io.Writer,
    source: transcript_blocks.LineProvenance,
) !void {
    switch (source) {
        .entry => |entry| try writer.print(
            "entry:{d}:{s}",
            .{ entry.entry_id, @tagName(entry.entry_class) },
        ),
        .image => |image| try writer.print(
            "image:{d}:{d}:{d}/{d}",
            .{ image.entry_id, image.image_id, image.row_index + 1, image.row_count },
        ),
        .folded_command_output => |output| {
            if (output.entry_id) |entry_id| {
                try writer.print(
                    "folded_command_output:{d}:{s}",
                    .{ entry_id, @tagName(output.stream) },
                );
            } else {
                try writer.print(
                    "folded_command_output:none:{s}",
                    .{@tagName(output.stream)},
                );
            }
        },
        else => try writer.writeAll(@tagName(source)),
    }
}

test "activity selector matches normal frame activity" {
    try std.testing.expect(activityMatches(null, .none));
    try std.testing.expect(activityMatches(.none, .none));
    try std.testing.expect(activityMatches(
        .turn_thinking,
        .{ .turn_thinking = .{ .label = "thinking" } },
    ));
    try std.testing.expect(activityMatches(
        .tool_slot,
        .{ .tool_slot = .{
            .entry_id = 1,
            .fallback_label = "Running sleep 5",
            .active = true,
            .kind = .command,
        } },
    ));
    try std.testing.expect(!activityMatches(
        .turn_thinking,
        .{ .tool_slot = .{
            .entry_id = 1,
            .fallback_label = "Running sleep 5",
            .active = true,
            .kind = .command,
        } },
    ));
}
