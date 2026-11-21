//! `execute`: runs a short JavaScript program in the code-mode sandbox. Each
//! `await tools.<name>(args)` the program makes comes back to fx, which runs
//! it through the same admission as a direct call. Only the program's return
//! value, its console output, and a list of its tool calls reach the model.

const std = @import("std");
const sandbox = @import("../../core/code_mode/sandbox.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    code: []u8,
};

const invalid_arguments = "execute arguments are invalid. Send {\"code\": \"<JavaScript>\"} with a non-empty program.";

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments) },
    };
    defer parsed.deinit();
    const code = codeArgument(parsed.value) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments) };
    };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .code = try ctx.allocator.dupe(u8, code) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn codeArgument(value: std.json.Value) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const code = switch (object.get("code") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    if (std.mem.trim(u8, code, " \t\r\n").len == 0) return null;
    return code;
}

fn inputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    alloc.free(input.code);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    if (input.as(Input).code.len > sandbox.max_source_bytes) {
        return try ctx.allocator.dupe(u8, "The program is over 1 MiB. Send a shorter program.");
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    // Everything below needs the engine, which libfx doesn't build.
    if (comptime !sandbox.available) {
        return .{ .failure = try ctx.allocator.dupe(u8, "Code mode isn't available in this build.") };
    }
    const provider = ctx.code_mode_provider orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "Code mode isn't available here.") };
    };
    var recorder: CallRecorder = .{ .provider = provider, .gpa = ctx.allocator };
    defer recorder.deinit();
    const report = try sandbox.run(ctx.allocator, io_mod.getIo(), input.as(Input).code, .{}, recorder.caller());
    defer report.deinit(ctx.allocator);
    if (report.result == .cancelled) return error.Cancelled;
    const text = try formatReport(ctx.allocator, report, recorder.calls.items);
    return switch (report.result) {
        .returned => .{ .success = text },
        else => .{ .failure = text },
    };
}

const CallRecord = struct {
    name: []u8,
    status: tool_dispatch.NestedToolResult.Status,
};

/// Passes each of the program's calls to the runtime's provider and keeps a
/// record of it for the summary.
const CallRecorder = struct {
    provider: tool_dispatch.CodeModeProvider,
    gpa: Allocator,
    calls: std.ArrayList(CallRecord) = .empty,

    fn caller(recorder: *CallRecorder) sandbox.Caller {
        return .{ .context = recorder, .call_fn = callTool, .cancelled_fn = isCancelled };
    }

    fn deinit(recorder: *CallRecorder) void {
        for (recorder.calls.items) |record| recorder.gpa.free(record.name);
        recorder.calls.deinit(recorder.gpa);
    }

    fn callTool(context: *anyopaque, arena: Allocator, name: []const u8, args_json: []const u8) sandbox.CallerError!sandbox.CallResult {
        const recorder: *CallRecorder = @ptrCast(@alignCast(context));
        const result: tool_dispatch.NestedToolResult = recorder.provider.call(arena, name, args_json) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .text = try arena.print("The {s} call failed: {t}.", .{ name, err }), .status = .failed },
        };
        const record_name = try recorder.gpa.dupe(u8, name);
        errdefer recorder.gpa.free(record_name);
        try recorder.calls.append(recorder.gpa, .{ .name = record_name, .status = result.status });
        return .{ .ok = result.status == .ok, .text = result.text };
    }

    fn isCancelled(context: *anyopaque) bool {
        const recorder: *CallRecorder = @ptrCast(@alignCast(context));
        return recorder.provider.cancelled();
    }
};

/// Caller owns the returned text.
fn formatReport(alloc: Allocator, report: sandbox.Report, calls: []const CallRecord) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    writeReport(&out.writer, report, calls) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeReport(w: *std.Io.Writer, report: sandbox.Report, calls: []const CallRecord) std.Io.Writer.Error!void {
    switch (report.result) {
        .returned => |json| try w.print("result: {s}\n", .{json orelse "undefined"}),
        .threw => |text| try w.print("error: {s}\n", .{text}),
        .timed_out => try w.writeAll("error: The program ran past its 30 s of JavaScript time and was stopped. Time spent in tool calls doesn't count.\n"),
        .unsettled => try w.writeAll("error: The program awaited something that never settled. Only tools.* calls can be awaited.\n"),
        .failed => |text| try w.print("error: {s}\n", .{text}),
        .cancelled => try w.writeAll("error: cancelled\n"),
    }
    if (report.logs.len > 0) {
        try w.writeAll("logs:\n");
        try w.writeAll(report.logs);
        if (report.logs_truncated) try w.writeAll("[logs truncated]\n");
    }
    try writeCallList(w, calls);
}

/// Every call in order, with consecutive calls of one tool and status on
/// one line.
fn writeCallList(w: *std.Io.Writer, calls: []const CallRecord) std.Io.Writer.Error!void {
    try w.print("tool calls: {d}\n", .{calls.len});
    var index: usize = 0;
    while (index < calls.len) {
        const first = calls[index];
        var end = index + 1;
        while (end < calls.len and calls[end].status == first.status and std.mem.eql(u8, calls[end].name, first.name)) end += 1;
        try w.print("  {s} {t}", .{ first.name, first.status });
        if (end - index > 1) try w.print(" x{d}", .{end - index});
        try w.writeByte('\n');
        index = end;
    }
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Each call the program makes is admitted on its own, so the program as a
/// whole commits to nothing.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "execute decode rejects a missing or empty program" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"code\":\"  \"}", "{\"code\":1}", "[]" }) |args| {
        const decoded = try decode(.{ .allocator = alloc }, args);
        switch (decoded) {
            .input => |decoded_input| {
                decoded_input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
            .failure => |failure| {
                defer alloc.free(failure);
                try std.testing.expectEqualStrings(invalid_arguments, failure);
            },
        }
    }
}

test "execute lists its calls in order and merges runs of the same tool and status" {
    const names = [_][]u8{ @constCast("read_file"), @constCast("shell") };
    const calls = [_]CallRecord{
        .{ .name = names[0], .status = .ok },
        .{ .name = names[0], .status = .ok },
        .{ .name = names[1], .status = .held },
        .{ .name = names[0], .status = .failed },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, .{ .result = .{ .returned = @constCast("[1]") }, .logs = "a\n" }, &calls);
    try std.testing.expectEqualStrings(
        \\result: [1]
        \\logs:
        \\a
        \\tool calls: 4
        \\  read_file ok x2
        \\  shell held
        \\  read_file failed
        \\
    , out.written());
}
