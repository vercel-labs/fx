const std = @import("std");
const command_contract = @import("../execution/command_contract.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const max_info_bytes: usize = 4 * 1024;
pub const max_command_bytes: usize = 64 * 1024;
const max_output_bytes: usize = 64 * 1024;
pub const min_timeout_ms: u32 = 1;
pub const max_timeout_ms: u32 = 30_000;

const ResultRecord = extern struct {
    exit_code: i32,
    stdout_offset: u32,
    stdout_copied: u32,
    stdout_total: u32,
    stderr_offset: u32,
    stderr_copied: u32,
    stderr_total: u32,
    flags: u32,
};

comptime {
    std.debug.assert(@sizeOf(ResultRecord) == 32);
}

extern "fx" fn fx_workspace_available() i32;
extern "fx" fn fx_workspace_info(out_ptr: [*]u8, out_cap: usize) i32;
extern "fx" fn fx_workspace_exec(
    command_ptr: [*]const u8,
    command_len: usize,
    timeout_ms: u32,
    output_ptr: [*]u8,
    output_cap: usize,
    result_ptr: *ResultRecord,
) i32;

const ImportedHost = struct {
    fn workspaceAvailable() i32 {
        return fx_workspace_available();
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        return fx_workspace_info(out_ptr, out_cap);
    }

    fn workspaceExec(
        command_ptr: [*]const u8,
        command_len: usize,
        timeout_ms: u32,
        output_ptr: [*]u8,
        output_cap: usize,
        result_ptr: *ResultRecord,
    ) i32 {
        return fx_workspace_exec(
            command_ptr,
            command_len,
            timeout_ms,
            output_ptr,
            output_cap,
            result_ptr,
        );
    }
};

pub const ExecuteError = Allocator.Error || error{
    InvalidWorkspaceInput,
    InvalidWorkspaceResult,
    WriteFailed,
    WorkspaceDeadline,
    WorkspaceHostFailure,
    WorkspaceUnavailable,
};

pub const Executor = struct {
    execute_fn: *const fn (
        Allocator,
        []const u8,
        []const u8,
        u32,
    ) ExecuteError!command_contract.RunCommandResult,

    pub fn execute(
        self: Executor,
        alloc: Allocator,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: u32,
    ) ExecuteError!command_contract.RunCommandResult {
        return self.execute_fn(alloc, command, cwd, timeout_ms);
    }
};

pub const Permission = enum {
    allow_sandboxed,
    prompt,
};

const PathSpan = struct {
    offset: u16,
    len: u16,
};

pub const Info = struct {
    storage: [max_info_bytes]u8 = undefined,
    root_span: PathSpan,
    cwd_span: PathSpan,
    home_span: PathSpan,
    git_available: bool,
    ephemeral: bool,
    permission: Permission,

    pub fn root(self: *const Info) []const u8 {
        return self.path(self.root_span);
    }

    pub fn cwd(self: *const Info) []const u8 {
        return self.path(self.cwd_span);
    }

    pub fn home(self: *const Info) []const u8 {
        return self.path(self.home_span);
    }

    fn path(self: *const Info, span: PathSpan) []const u8 {
        const start: usize = span.offset;
        return self.storage[start .. start + span.len];
    }
};

const JsonInfo = struct {
    version: u32,
    root: []const u8,
    cwd: []const u8,
    home: []const u8,
    git: bool,
    ephemeral: bool,
    permission: []const u8,
};

pub fn Adapter(comptime Host: type) type {
    return struct {
        pub fn executor() Executor {
            return .{ .execute_fn = executeForProvider };
        }

        fn executeForProvider(
            alloc: Allocator,
            command: []const u8,
            cwd: []const u8,
            timeout_ms: u32,
        ) ExecuteError!command_contract.RunCommandResult {
            return execute(alloc, command, cwd, timeout_ms);
        }

        pub fn loadInfo(alloc: Allocator) !Info {
            return switch (Host.workspaceAvailable()) {
                0 => error.WorkspaceUnavailable,
                1 => loadAvailableInfo(alloc),
                else => error.InvalidContract,
            };
        }

        fn loadAvailableInfo(alloc: Allocator) !Info {
            var buffer: [max_info_bytes]u8 = undefined;
            const result = Host.workspaceInfo(&buffer, buffer.len);
            if (result < 0) return switch (result) {
                -1 => error.WorkspaceHostFailure,
                -2 => error.WorkspaceUnavailable,
                -3 => error.WorkspaceInfoTooSmall,
                -4 => error.InvalidContract,
                else => error.InvalidContract,
            };
            const len: usize = @intCast(result);
            if (len > buffer.len) return error.InvalidContract;

            const parsed = std.json.parseFromSlice(JsonInfo, alloc, buffer[0..len], .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidContract,
            };
            defer parsed.deinit();
            const value = parsed.value;
            if (value.version != 1 or value.git or !value.ephemeral) return error.InvalidContract;
            if (!validAbsolutePath(value.root) or
                !validAbsolutePath(value.cwd) or
                !validAbsolutePath(value.home) or
                !std.mem.eql(u8, value.root, value.cwd)) return error.InvalidContract;
            const permission: Permission = if (std.mem.eql(u8, value.permission, "allow-sandboxed"))
                .allow_sandboxed
            else if (std.mem.eql(u8, value.permission, "prompt"))
                .prompt
            else
                return error.InvalidContract;

            var info = Info{
                .root_span = undefined,
                .cwd_span = undefined,
                .home_span = undefined,
                .git_available = false,
                .ephemeral = true,
                .permission = permission,
            };
            var offset: usize = 0;
            info.root_span = copyPath(&info.storage, &offset, value.root) orelse return error.InvalidContract;
            info.cwd_span = copyPath(&info.storage, &offset, value.cwd) orelse return error.InvalidContract;
            info.home_span = copyPath(&info.storage, &offset, value.home) orelse return error.InvalidContract;
            return info;
        }

        pub fn execute(
            alloc: Allocator,
            command: []const u8,
            cwd: []const u8,
            timeout_ms: u32,
        ) ExecuteError!command_contract.RunCommandResult {
            if (command.len > max_command_bytes or
                !std.unicode.utf8ValidateSlice(command) or
                std.mem.findScalar(u8, command, 0) != null or
                timeout_ms < min_timeout_ms or
                timeout_ms > max_timeout_ms) return error.InvalidWorkspaceInput;

            const output = try alloc.alloc(u8, max_output_bytes);
            defer alloc.free(output);
            var record: ResultRecord = undefined;
            const started_ms = io_mod.milliTimestamp();
            const status = Host.workspaceExec(
                command.ptr,
                command.len,
                timeout_ms,
                output.ptr,
                output.len,
                &record,
            );
            const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
            if (status != 0) return switch (status) {
                -1 => error.WorkspaceHostFailure,
                -2 => error.WorkspaceUnavailable,
                -3 => .{
                    .output = "",
                    .cancelled = true,
                    .command_result = .{
                        .command = command,
                        .cwd = cwd,
                        .duration_ms = duration_ms,
                    },
                },
                -4 => error.InvalidWorkspaceInput,
                -5 => error.WorkspaceDeadline,
                else => error.InvalidWorkspaceResult,
            };

            const stdout = try checkedOutputSlice(
                output,
                record.stdout_offset,
                record.stdout_copied,
            );
            const stderr = try checkedOutputSlice(
                output,
                record.stderr_offset,
                record.stderr_copied,
            );
            if (rangesOverlap(
                record.stdout_offset,
                record.stdout_copied,
                record.stderr_offset,
                record.stderr_copied,
            ) or !std.unicode.utf8ValidateSlice(stdout) or
                !std.unicode.utf8ValidateSlice(stderr) or
                record.stdout_total < record.stdout_copied or
                record.stderr_total < record.stderr_copied or
                record.flags & ~@as(u32, 1) != 0) return error.InvalidWorkspaceResult;

            const truncated = record.flags & 1 != 0;
            const copied_total = @as(u64, record.stdout_copied) + record.stderr_copied;
            const output_total = @as(u64, record.stdout_total) + record.stderr_total;
            if ((!truncated and output_total != copied_total) or
                (truncated and output_total <= copied_total)) return error.InvalidWorkspaceResult;

            var formatted = try command_contract.formatCommandResult(alloc, .{
                .command = command,
                .cwd = cwd,
                .status = .{ .exit_code = record.exit_code },
                .stdout_display = stdout,
                .stderr_display = stderr,
                .stdout_bytes = record.stdout_total,
                .stderr_bytes = record.stderr_total,
                .duration_ms = duration_ms,
            });
            var metadata = formatted.command_result.?;
            metadata.truncated = truncated;
            formatted.command_result = metadata;
            return formatted;
        }
    };
}

pub fn HostRuntime(comptime Host: type) type {
    return struct {
        workspace_info: ?Info = null,

        pub fn init(alloc: Allocator) !@This() {
            return .{ .workspace_info = try Adapter(Host).loadInfo(alloc) };
        }

        pub fn available(self: *const @This()) bool {
            return self.workspace_info != null;
        }

        pub fn info(self: *const @This()) ?*const Info {
            return if (self.workspace_info) |*metadata| metadata else null;
        }

        pub fn executor(self: *const @This()) ?Executor {
            if (!self.available()) return null;
            return Adapter(Host).executor();
        }
    };
}

pub const Runtime = HostRuntime(ImportedHost);

fn checkedOutputSlice(output: []const u8, offset_raw: u32, len_raw: u32) ![]const u8 {
    const offset: usize = offset_raw;
    const len: usize = len_raw;
    if (offset > output.len or len > output.len - offset) return error.InvalidWorkspaceResult;
    return output[offset .. offset + len];
}

fn rangesOverlap(a_offset: u32, a_len: u32, b_offset: u32, b_len: u32) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @as(u64, a_offset) + a_len;
    const b_end = @as(u64, b_offset) + b_len;
    return @as(u64, a_offset) < b_end and @as(u64, b_offset) < a_end;
}

fn elapsedMs(started_ms: i64, ended_ms: i64) u64 {
    return @intCast(@max(ended_ms - started_ms, 0));
}

fn copyPath(storage: *[max_info_bytes]u8, offset: *usize, path: []const u8) ?PathSpan {
    if (path.len > storage.len - offset.*) return null;
    const start = offset.*;
    @memcpy(storage[start .. start + path.len], path);
    offset.* += path.len;
    return .{ .offset = @intCast(start), .len = @intCast(path.len) };
}

fn validAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or !std.unicode.utf8ValidateSlice(path)) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

const valid_info_json =
    "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow-sandboxed\"}";

const FakeInfoHost = struct {
    var available_result: i32 = 1;
    var info_result: ?i32 = null;
    var info_json: []const u8 = valid_info_json;

    fn workspaceAvailable() i32 {
        return available_result;
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        if (info_result) |result| return result;
        if (info_json.len > out_cap) return -3;
        @memcpy(out_ptr[0..info_json.len], info_json);
        return @intCast(info_json.len);
    }

    fn workspaceExec(
        _: [*]const u8,
        _: usize,
        _: u32,
        _: [*]u8,
        _: usize,
        _: *ResultRecord,
    ) i32 {
        return -2;
    }
};

test "workspace info is unavailable when the host adapter is absent" {
    FakeInfoHost.available_result = 0;
    defer FakeInfoHost.available_result = 1;

    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
}

test "workspace info accepts the bounded v1 browser contract" {
    const info = try Adapter(FakeInfoHost).loadInfo(std.testing.allocator);
    try std.testing.expectEqualStrings("/workspace", info.root());
    try std.testing.expectEqualStrings("/workspace", info.cwd());
    try std.testing.expectEqualStrings("/home/visitor", info.home());
    try std.testing.expect(!info.git_available);
    try std.testing.expect(info.ephemeral);
    try std.testing.expectEqual(Permission.allow_sandboxed, info.permission);
}

test "workspace runtime keeps one validated metadata and executor snapshot" {
    FakeInfoHost.available_result = 1;
    const runtime = try HostRuntime(FakeInfoHost).init(std.testing.allocator);
    FakeInfoHost.available_result = 0;
    defer FakeInfoHost.available_result = 1;

    try std.testing.expect(runtime.available());
    try std.testing.expectEqualStrings("/workspace", runtime.info().?.root());
    try std.testing.expect(runtime.executor() != null);
}

test "workspace info rejects invalid host contracts and stable error codes" {
    defer {
        FakeInfoHost.available_result = 1;
        FakeInfoHost.info_result = null;
        FakeInfoHost.info_json = valid_info_json;
    }
    const invalid = [_][]const u8{
        "{\"version\":2,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace/./src\",\"cwd\":\"/workspace/src\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace/src\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace-other\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home\\u0000visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":true,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":false,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow\"}",
    };
    for (invalid) |payload| {
        FakeInfoHost.info_json = payload;
        try std.testing.expectError(
            error.InvalidContract,
            Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
        );
    }

    FakeInfoHost.info_json =
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}";
    const prompt_info = try Adapter(FakeInfoHost).loadInfo(std.testing.allocator);
    try std.testing.expectEqual(Permission.prompt, prompt_info.permission);

    FakeInfoHost.info_result = -3;
    try std.testing.expectError(
        error.WorkspaceInfoTooSmall,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
    FakeInfoHost.info_result = @intCast(max_info_bytes + 1);
    try std.testing.expectError(
        error.InvalidContract,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
}

const FakeExecHost = struct {
    var status: i32 = 0;
    var stdout: []const u8 = "";
    var stderr: []const u8 = "";
    var stdout_total: u32 = 0;
    var stderr_total: u32 = 0;
    var exit_code: i32 = 0;
    var flags: u32 = 0;
    var record_override: ?ResultRecord = null;
    var calls: usize = 0;

    fn workspaceExec(
        _: [*]const u8,
        _: usize,
        _: u32,
        output_ptr: [*]u8,
        output_cap: usize,
        result_ptr: *ResultRecord,
    ) i32 {
        calls += 1;
        if (status != 0) return status;
        if (stdout.len + stderr.len > output_cap) return -4;
        @memcpy(output_ptr[0..stdout.len], stdout);
        @memcpy(output_ptr[stdout.len .. stdout.len + stderr.len], stderr);
        result_ptr.* = record_override orelse .{
            .exit_code = exit_code,
            .stdout_offset = 0,
            .stdout_copied = @intCast(stdout.len),
            .stdout_total = if (stdout_total == 0) @intCast(stdout.len) else stdout_total,
            .stderr_offset = @intCast(stdout.len),
            .stderr_copied = @intCast(stderr.len),
            .stderr_total = if (stderr_total == 0) @intCast(stderr.len) else stderr_total,
            .flags = flags,
        };
        return 0;
    }

    fn reset() void {
        status = 0;
        stdout = "";
        stderr = "";
        stdout_total = 0;
        stderr_total = 0;
        exit_code = 0;
        flags = 0;
        record_override = null;
        calls = 0;
    }
};

test "workspace exec maps nonzero foreground output through the command contract" {
    FakeExecHost.reset();
    FakeExecHost.exit_code = 7;
    FakeExecHost.stdout = "partial output\n";
    FakeExecHost.stderr = "command failed\n";

    const result = try Adapter(FakeExecHost).execute(
        std.testing.allocator,
        "test -f missing",
        "/workspace",
        5000,
    );
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(usize, 1), FakeExecHost.calls);
    try std.testing.expect(std.mem.find(u8, result.output, "exit_code=7") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "<stdout>\npartial output\n</stdout>") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "<stderr>\ncommand failed\n</stderr>") != null);
    const metadata = result.command_result.?;
    try std.testing.expectEqual(@as(?i64, 7), metadata.exit_code);
    try std.testing.expect(metadata.signal == null);
    try std.testing.expect(!metadata.timed_out);
    try std.testing.expect(metadata.duration_ms != null);
}

test "workspace exec preserves bounded previews and total byte counts" {
    FakeExecHost.reset();
    FakeExecHost.stdout = "prefix";
    FakeExecHost.stderr = "error";
    FakeExecHost.stdout_total = 70_000;
    FakeExecHost.stderr_total = 9000;
    FakeExecHost.flags = 1;

    const result = try Adapter(FakeExecHost).execute(
        std.testing.allocator,
        "generate output",
        "/workspace",
        30_000,
    );
    defer std.testing.allocator.free(result.output);

    const metadata = result.command_result.?;
    try std.testing.expectEqual(@as(usize, 70_000), metadata.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 9000), metadata.stderr_bytes);
    try std.testing.expect(metadata.truncated);
    try std.testing.expect(metadata.output_file == null);
    try std.testing.expect(metadata.stdout_file == null);
    try std.testing.expect(metadata.stderr_file == null);
}

test "workspace exec maps host abort without inventing a signal" {
    FakeExecHost.reset();
    FakeExecHost.status = -3;

    const result = try Adapter(FakeExecHost).execute(
        std.testing.allocator,
        "long command",
        "/workspace",
        30_000,
    );
    try std.testing.expect(result.cancelled);
    const metadata = result.command_result.?;
    try std.testing.expect(metadata.exit_code == null);
    try std.testing.expect(metadata.signal == null);
    try std.testing.expect(!metadata.timed_out);
}

test "workspace exec rejects command and timeout bounds before the host import" {
    FakeExecHost.reset();
    const oversized = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    try std.testing.expectError(
        error.InvalidWorkspaceInput,
        Adapter(FakeExecHost).execute(std.testing.allocator, oversized, "/workspace", 30_000),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceInput,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", 0),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceInput,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", max_timeout_ms + 1),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceInput,
        Adapter(FakeExecHost).execute(std.testing.allocator, "bad\x00command", "/workspace", 1000),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceInput,
        Adapter(FakeExecHost).execute(std.testing.allocator, "bad\xff", "/workspace", 1000),
    );
    try std.testing.expectEqual(@as(usize, 0), FakeExecHost.calls);
}

test "workspace exec rejects invalid output ranges utf8 and truncation records" {
    FakeExecHost.reset();
    FakeExecHost.record_override = .{
        .exit_code = 0,
        .stdout_offset = max_output_bytes - 2,
        .stdout_copied = 3,
        .stdout_total = 3,
        .stderr_offset = 0,
        .stderr_copied = 0,
        .stderr_total = 0,
        .flags = 0,
    };
    try std.testing.expectError(
        error.InvalidWorkspaceResult,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", 1000),
    );

    FakeExecHost.reset();
    FakeExecHost.stdout = "abcd";
    FakeExecHost.stderr = "efgh";
    FakeExecHost.record_override = .{
        .exit_code = 0,
        .stdout_offset = 0,
        .stdout_copied = 4,
        .stdout_total = 4,
        .stderr_offset = 2,
        .stderr_copied = 4,
        .stderr_total = 4,
        .flags = 0,
    };
    try std.testing.expectError(
        error.InvalidWorkspaceResult,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", 1000),
    );

    FakeExecHost.reset();
    FakeExecHost.stdout = "\xff";
    try std.testing.expectError(
        error.InvalidWorkspaceResult,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", 1000),
    );

    FakeExecHost.reset();
    FakeExecHost.stdout = "preview";
    FakeExecHost.flags = 1;
    try std.testing.expectError(
        error.InvalidWorkspaceResult,
        Adapter(FakeExecHost).execute(std.testing.allocator, "pwd", "/workspace", 1000),
    );
}
