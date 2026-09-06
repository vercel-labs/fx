const std = @import("std");
const command_output_content = @import("../tooling/command_output_content.zig");

pub const CommandOutputStream = command_output_content.Stream;
pub const CommandOutputCallback = command_output_content.Callback;

pub const CommandResult = struct {
    command: []const u8,
    cwd: []const u8,
    exit_code: ?i64 = null,
    signal: ?u32 = null,
    timed_out: bool = false,
    termination_indeterminate: bool = false,
    output_incomplete: bool = false,
    duration_ms: ?u64 = null,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    truncated: bool = false,
    output_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,

    pub fn writeJson(self: CommandResult, writer: *std.Io.Writer) !void {
        try writeCommandJson(self, writer);
    }

    pub fn toJson(self: CommandResult, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }
};

pub const RunCommandResult = struct {
    output: []const u8,
    command_result: ?CommandResult = null,
    cancelled: bool = false,
};

pub const CommandStatus = union(enum) {
    exit_code: i64,
    signal: u32,
    finished,
    indeterminate,
};

pub const CommandResultSnapshot = struct {
    command: []const u8,
    cwd: []const u8,
    status: CommandStatus,
    stdout_display: []const u8,
    stderr_display: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    output_incomplete: bool = false,
    duration_ms: ?u64 = null,
};

pub const StatusProjection = struct {
    exit_code: ?i64,
    signal: ?u32,
    termination_indeterminate: bool,
};

pub fn formatCommandResult(
    alloc: std.mem.Allocator,
    snapshot: CommandResultSnapshot,
) !RunCommandResult {
    const stdout_text = std.mem.trim(u8, snapshot.stdout_display, " \r\n\t");
    const stderr_text = std.mem.trim(u8, snapshot.stderr_display, " \r\n\t");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeStatusLine(&out.writer, snapshot.status);
    try writeOutputEnvelopes(&out.writer, stdout_text, stderr_text);
    const status = projectStatus(snapshot.status);

    return .{
        .output = try out.toOwnedSlice(),
        .command_result = .{
            .command = snapshot.command,
            .cwd = snapshot.cwd,
            .exit_code = status.exit_code,
            .signal = status.signal,
            .termination_indeterminate = status.termination_indeterminate,
            .output_incomplete = snapshot.output_incomplete,
            .duration_ms = snapshot.duration_ms,
            .stdout_bytes = snapshot.stdout_bytes,
            .stderr_bytes = snapshot.stderr_bytes,
        },
    };
}

pub fn writeStatusLine(writer: *std.Io.Writer, status: CommandStatus) !void {
    switch (status) {
        .exit_code => |code| try writer.print("exit_code={d}\n", .{code}),
        .signal => |signal| try writer.print("signal={d}\n", .{signal}),
        .finished => try writer.writeAll("process finished\n"),
        .indeterminate => try writer.writeAll(
            "termination_indeterminate=true\n" ++
                "message=the command was started, but fx could not confirm its final process status; do not retry unchanged because side effects may already exist\n",
        ),
    }
}

fn writeOutputEnvelopes(writer: *std.Io.Writer, stdout_text: []const u8, stderr_text: []const u8) !void {
    if (stdout_text.len > 0) {
        try writer.writeAll("<stdout>\n");
        try writer.writeAll(stdout_text);
        try writer.writeAll("\n</stdout>\n");
    }
    if (stderr_text.len > 0) {
        try writer.writeAll("<stderr>\n");
        try writer.writeAll(stderr_text);
        try writer.writeAll("\n</stderr>\n");
    }
    if (stdout_text.len == 0 and stderr_text.len == 0) {
        try writer.writeAll("(no output)\n");
    }
}

pub fn projectStatus(
    status: CommandStatus,
) StatusProjection {
    return switch (status) {
        .exit_code => |code| .{
            .exit_code = code,
            .signal = null,
            .termination_indeterminate = false,
        },
        .signal => |signal| .{
            .exit_code = null,
            .signal = signal,
            .termination_indeterminate = false,
        },
        .finished => .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        },
        .indeterminate => .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = true,
        },
    };
}

fn writeCommandJson(result: CommandResult, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"kind\":\"command\"");
    try writeStringField(writer, "command", result.command);
    try writeStringField(writer, "cwd", result.cwd);
    try writeOptionalIntField(writer, "exit_code", result.exit_code);
    try writeOptionalIntField(writer, "signal", result.signal);
    try writeBoolField(writer, "timed_out", result.timed_out);
    if (result.termination_indeterminate) {
        try writeBoolField(writer, "termination_indeterminate", true);
    }
    if (result.output_incomplete) {
        try writeBoolField(writer, "output_incomplete", true);
    }
    try writeOptionalIntField(writer, "duration_ms", result.duration_ms);
    try writeIntField(writer, "stdout_bytes", result.stdout_bytes);
    try writeIntField(writer, "stderr_bytes", result.stderr_bytes);
    try writeBoolField(writer, "truncated", result.truncated);
    try writeOptionalStringField(writer, "output_file", result.output_file);
    try writeOptionalStringField(writer, "stdout_file", result.stdout_file);
    try writeOptionalStringField(writer, "stderr_file", result.stderr_file);
    try writer.writeByte('}');
}

fn writeStringField(writer: *std.Io.Writer, comptime name: []const u8, value: []const u8) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalStringField(writer: *std.Io.Writer, comptime name: []const u8, value: ?[]const u8) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeBoolField(writer: *std.Io.Writer, comptime name: []const u8, value: bool) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try writer.writeAll(if (value) "true" else "false");
}

fn writeIntField(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    try writer.print("{d}", .{value});
}

fn writeOptionalIntField(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) !void {
    try writer.writeAll(",\"" ++ name ++ "\":");
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

test "foreground result preserves envelopes metadata and json" {
    const result = try formatCommandResult(std.testing.allocator, .{
        .command = "printf hello",
        .cwd = "/tmp",
        .status = .{ .exit_code = 7 },
        .stdout_display = " hello\n",
        .stderr_display = " warn\n",
        .stdout_bytes = 7,
        .stderr_bytes = 6,
        .duration_ms = 12,
    });
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqualStrings(
        "exit_code=7\n<stdout>\nhello\n</stdout>\n<stderr>\nwarn\n</stderr>\n",
        result.output,
    );
    const command = result.command_result.?;
    try std.testing.expectEqualStrings("printf hello", command.command);
    try std.testing.expectEqualStrings("/tmp", command.cwd);
    try std.testing.expectEqual(@as(?i64, 7), command.exit_code);
    try std.testing.expectEqual(@as(?u32, null), command.signal);
    try std.testing.expectEqual(@as(?u64, 12), command.duration_ms);
    try std.testing.expectEqual(@as(usize, 7), command.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 6), command.stderr_bytes);

    const json = try result.command_result.?.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"command\",\"command\":\"printf hello\",\"cwd\":\"/tmp\",\"exit_code\":7,\"signal\":null,\"timed_out\":false,\"duration_ms\":12,\"stdout_bytes\":7,\"stderr_bytes\":6,\"truncated\":false,\"output_file\":null,\"stdout_file\":null,\"stderr_file\":null}",
        json,
    );
}

test "foreground result preserves empty finished output" {
    const result = try formatCommandResult(std.testing.allocator, .{
        .command = "cmd",
        .cwd = "/tmp",
        .status = .finished,
        .stdout_display = "",
        .stderr_display = "",
        .stdout_bytes = 0,
        .stderr_bytes = 0,
    });
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqualStrings("process finished\n(no output)\n", result.output);
}

test "foreground result represents indeterminate termination without implying no execution" {
    const result = try formatCommandResult(std.testing.allocator, .{
        .command = "printf effect > marker",
        .cwd = "/tmp",
        .status = .indeterminate,
        .stdout_display = "observed output",
        .stderr_display = "",
        .stdout_bytes = 15,
        .stderr_bytes = 0,
    });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.find(
        u8,
        result.output,
        "termination_indeterminate=true",
    ) != null);
    try std.testing.expect(std.mem.find(u8, result.output, "do not retry unchanged") != null);
    const command = result.command_result.?;
    try std.testing.expect(command.termination_indeterminate);
    try std.testing.expectEqual(@as(?i64, null), command.exit_code);
    try std.testing.expectEqual(@as(?u32, null), command.signal);
    const json = try result.command_result.?.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(
        u8,
        json,
        "\"termination_indeterminate\":true",
    ) != null);
}

test "command result preserves observed status when output is incomplete" {
    const result = try formatCommandResult(std.testing.allocator, .{
        .command = "printf effect > marker",
        .cwd = "/tmp",
        .status = .{ .exit_code = 0 },
        .stdout_display = "partial output",
        .stderr_display = "",
        .stdout_bytes = 14,
        .stderr_bytes = 0,
        .output_incomplete = true,
    });
    defer std.testing.allocator.free(result.output);

    const command = result.command_result.?;
    try std.testing.expectEqual(@as(?i64, 0), command.exit_code);
    try std.testing.expect(command.output_incomplete);

    const json = try command.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(
        u8,
        json,
        "\"output_incomplete\":true",
    ) != null);
}
