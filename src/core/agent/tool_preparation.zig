const std = @import("std");
const context_contract = @import("../workspace/context_contract.zig");
const io_mod = @import("../shared/io.zig");
const permissions = @import("../permissions/permissions.zig");
const types = @import("../shared/types.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

/// Owned terminal output produced by a loop-specific classifier. The
/// preparation result takes ownership of `model_output` on success.
pub const CallbackTerminal = struct {
    model_output: []u8,
    status: ToolStatus = .success,
};

pub const ClassifierFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!?CallbackTerminal;

pub const CandidateClassifierFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!bool;

pub const Classifiers = struct {
    ctx: ?*anyopaque = null,
    idempotent: ClassifierFn,
    validation: ClassifierFn,
    availability: ClassifierFn,
    deferred_dynamic: ?CandidateClassifierFn = null,
};

pub const Config = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    classifiers: Classifiers,
};

pub const ToolStatus = enum {
    success,
    failure,
};

pub const TerminalKind = enum {
    idempotent_skip,
    validation_failure,
    availability_failure,
    unsupported,
    file_mutation_failure,
};

/// A terminal classification made before permission, visible lifecycle, or
/// execution. `model_output == null` for unsupported calls so each live loop
/// can retain its existing exact unsupported-tool wording.
pub const Terminal = struct {
    kind: TerminalKind,
    model_output: ?[]u8 = null,
    status: ToolStatus = .failure,

    pub fn deinit(self: *Terminal, alloc: Allocator) void {
        if (self.model_output) |output| alloc.free(output);
        self.* = undefined;
    }
};

pub const CandidateKind = enum {
    registered,
    advertised_dynamic,
    deferred_dynamic,
    /// Applicability projection could not prove a canonical target, so the
    /// owning loop must preserve the existing permission/dispatch path.
    legacy_target_resolution,
};

/// One genuine execution candidate. Every target path is owned by this value.
pub const Candidate = struct {
    kind: CandidateKind,
    applicable_targets: []context_contract.ApplicableTarget = &.{},

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        freeApplicableTargets(alloc, self.applicable_targets);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    terminal: Terminal,
    candidate: Candidate,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .terminal => |*terminal| terminal.deinit(alloc),
            .candidate => |*candidate| candidate.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const ReadyCallBatch = struct {
    preparations: []?Result,
    /// Owns only the list storage; target paths remain owned by preparations.
    applicable_targets: std.ArrayList(context_contract.ApplicableTarget) = .empty,

    pub fn init(alloc: Allocator, call_count: usize) Allocator.Error!ReadyCallBatch {
        const preparations = try alloc.alloc(?Result, call_count);
        @memset(preparations, null);
        return .{ .preparations = preparations };
    }

    pub fn deinit(
        self: *ReadyCallBatch,
        storage_alloc: Allocator,
        preparation_alloc: Allocator,
    ) void {
        self.applicable_targets.deinit(preparation_alloc);
        for (self.preparations) |*maybe_preparation| {
            if (maybe_preparation.*) |*preparation| preparation.deinit(preparation_alloc);
        }
        storage_alloc.free(self.preparations);
        self.* = undefined;
    }

    pub fn prepare(
        self: *ReadyCallBatch,
        alloc: Allocator,
        index: usize,
        call: ToolCall,
        config: Config,
    ) !void {
        std.debug.assert(index < self.preparations.len);
        std.debug.assert(self.preparations[index] == null);

        var preparation = try prepareReadyCall(alloc, call, config);
        errdefer preparation.deinit(alloc);
        switch (preparation) {
            .terminal => {},
            .candidate => |candidate| {
                try self.applicable_targets.appendSlice(alloc, candidate.applicable_targets);
            },
        }
        self.preparations[index] = preparation;
    }
};

/// Classifies one effective `.ready` lifecycle call without permission,
/// presentation, execution, or product-state mutation.
pub fn prepareReadyCall(alloc: Allocator, call: ToolCall, config: Config) !Result {
    if (call.provenance == .provider_executed or call.argument_integrity != .valid) {
        return error.NotLifecycleReady;
    }
    try checkCancellation(config.cancel_flag);

    const tool = config.tool_registry.lookup(call.name) orelse {
        if (isAdvertisedDynamic(config.advertised_dynamic_tool_names, call.name)) {
            if (try classifyWithCallback(
                alloc,
                config.cancel_flag,
                config.classifiers,
                config.classifiers.validation,
                call,
            )) |terminal| {
                return .{ .terminal = terminalFromCallback(.validation_failure, terminal) };
            }
            if (try classifyWithCallback(
                alloc,
                config.cancel_flag,
                config.classifiers,
                config.classifiers.availability,
                call,
            )) |terminal| {
                return .{ .terminal = terminalFromCallback(.availability_failure, terminal) };
            }
            return .{ .candidate = .{ .kind = .advertised_dynamic } };
        }
        if (config.classifiers.deferred_dynamic) |classify| {
            if (try classify(config.classifiers.ctx, alloc, call)) {
                return .{ .candidate = .{ .kind = .deferred_dynamic } };
            }
        }
        return .{ .terminal = .{ .kind = .unsupported } };
    };

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.idempotent,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.idempotent_skip, terminal) };
    }

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.validation,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.validation_failure, terminal) };
    }

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.availability,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.availability_failure, terminal) };
    }
    const targets = if (file_mutation_contract.isToolName(call.name)) blk: {
        var projection = try tool_admission.prepareFileMutationCall(alloc, call, .{
            .tool_registry = config.tool_registry,
            .workspace_root = config.workspace_root,
        });
        switch (projection) {
            .tool_failure => |reason| {
                try checkCancellationWithOutput(alloc, config.cancel_flag, @constCast(reason));
                return .{ .terminal = .{
                    .kind = .file_mutation_failure,
                    .model_output = @constCast(reason),
                } };
            },
            .prepared => |*prepared| {
                defer prepared.deinit(alloc);
                break :blk try dupeSingleApplicableTarget(alloc, prepared.targetPath(), .file);
            },
        }
    } else switch (try prepareRegisteredApplicableTargets(alloc, config.workspace_root, config.access_scope, call, tool.*)) {
        .prepared => |prepared| prepared,
        .legacy_candidate => return .{ .candidate = .{ .kind = .legacy_target_resolution } },
    };
    errdefer freeApplicableTargets(alloc, targets);
    try checkCancellation(config.cancel_flag);

    return .{ .candidate = .{
        .kind = .registered,
        .applicable_targets = targets,
    } };
}

fn classifyWithCallback(
    alloc: Allocator,
    cancel_flag: ?*std.atomic.Value(bool),
    classifiers: Classifiers,
    classifier: ClassifierFn,
    call: ToolCall,
) anyerror!?CallbackTerminal {
    const terminal = try classifier(classifiers.ctx, alloc, call) orelse return null;
    errdefer alloc.free(terminal.model_output);
    try checkCancellation(cancel_flag);
    return terminal;
}

fn terminalFromCallback(kind: TerminalKind, terminal: CallbackTerminal) Terminal {
    return .{
        .kind = kind,
        .model_output = terminal.model_output,
        .status = terminal.status,
    };
}

fn checkCancellation(cancel_flag: ?*std.atomic.Value(bool)) error{Cancelled}!void {
    if (cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
}

fn checkCancellationWithOutput(
    alloc: Allocator,
    cancel_flag: ?*std.atomic.Value(bool),
    output: []u8,
) error{Cancelled}!void {
    checkCancellation(cancel_flag) catch |err| {
        alloc.free(output);
        return err;
    };
}

fn isAdvertisedDynamic(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const RegisteredTargetPreparation = union(enum) {
    prepared: []context_contract.ApplicableTarget,
    legacy_candidate,
};

fn prepareRegisteredApplicableTargets(
    alloc: Allocator,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope,
    call: ToolCall,
    tool: tool_dispatch.Tool,
) Allocator.Error!RegisteredTargetPreparation {
    if (try isCapturedCommandCall(alloc, call, tool)) {
        const command_cwd = permissions.resolveCommandCwdForCallInScope(
            alloc,
            access_scope orelse workspace_access.AccessScope.primaryOnly(workspace_root),
            call,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .legacy_candidate,
            };
        };
        defer alloc.free(@constCast(command_cwd));
        return .{ .prepared = try dupeSingleApplicableTarget(
            alloc,
            command_cwd,
            .directory,
        ) };
    }

    var permission_targets = permissions.permissionTargetsForCallInScope(
        alloc,
        access_scope orelse workspace_access.AccessScope.primaryOnly(workspace_root),
        call,
        tool.permission_target_kind,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .legacy_candidate,
        };
    };
    defer permission_targets.deinit(alloc);

    const target_kind = filesystemTargetKind(tool.executor_kind);
    const applicable_targets: []context_contract.ApplicableTarget = if (target_kind) |kind|
        try applicableTargetsFromPermissionTargets(alloc, permission_targets.items, kind)
    else
        @constCast(&.{});

    return .{ .prepared = applicable_targets };
}

fn isCapturedCommandCall(
    alloc: Allocator,
    call: ToolCall,
    tool: tool_dispatch.Tool,
) Allocator.Error!bool {
    if (tool.executor_kind == .run_command) return true;
    const expected_action = tool.captured_command_action orelse return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const action = parsed.value.object.get("action") orelse return false;
    return action == .string and std.mem.eql(u8, action.string, expected_action);
}

/// Reprojects a prepared registered ordinary candidate immediately before its
/// permission boundary. A mismatch means the scope used for project context is
/// no longer the scope the raw permission/dispatch path would observe.
pub fn ordinaryApplicableTargetsFresh(
    alloc: Allocator,
    call: ToolCall,
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    candidate: *const Candidate,
) Allocator.Error!bool {
    return ordinaryApplicableTargetsFreshInScope(
        alloc,
        call,
        tool_registry,
        workspace_root,
        null,
        candidate,
    );
}

pub fn ordinaryApplicableTargetsFreshInScope(
    alloc: Allocator,
    call: ToolCall,
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope,
    candidate: *const Candidate,
) Allocator.Error!bool {
    switch (candidate.kind) {
        .advertised_dynamic, .deferred_dynamic => return true,
        .registered => if (candidate.applicable_targets.len == 0) return true,
        .legacy_target_resolution => {},
    }
    const tool = tool_registry.lookup(call.name) orelse return false;

    const current_preparation = try prepareRegisteredApplicableTargets(
        alloc,
        workspace_root,
        access_scope,
        call,
        tool.*,
    );
    const current = switch (current_preparation) {
        .legacy_candidate => return candidate.kind == .legacy_target_resolution,
        .prepared => |targets| targets,
    };
    defer freeApplicableTargets(alloc, current);
    if (candidate.kind == .legacy_target_resolution) return current.len == 0;
    return applicableTargetsEqual(candidate.applicable_targets, current);
}

fn applicableTargetsEqual(
    expected: []const context_contract.ApplicableTarget,
    current: []const context_contract.ApplicableTarget,
) bool {
    if (expected.len != current.len) return false;
    for (expected, current) |left, right| {
        if (left.kind != right.kind or !std.mem.eql(u8, left.path, right.path)) {
            return false;
        }
    }
    return true;
}

fn applicableTargetsFromPermissionTargets(
    alloc: Allocator,
    permission_targets: []const permissions.PermissionCallTarget,
    kind: context_contract.TargetKind,
) Allocator.Error![]context_contract.ApplicableTarget {
    const targets = try alloc.alloc(context_contract.ApplicableTarget, permission_targets.len);
    var initialized: usize = 0;
    errdefer {
        for (targets[0..initialized]) |target| alloc.free(@constCast(target.path));
        alloc.free(targets);
    }
    for (permission_targets, targets) |permission_target, *target| {
        target.* = .{
            .path = try alloc.dupe(u8, permission_target.path),
            .kind = kind,
        };
        initialized += 1;
    }
    return targets;
}

fn filesystemTargetKind(kind: tool_dispatch.ExecutorKind) ?context_contract.TargetKind {
    return switch (kind) {
        .glob_files, .grep_files => .directory,
        .read_file => .file,
        else => null,
    };
}

fn dupeSingleApplicableTarget(
    alloc: Allocator,
    path: []const u8,
    kind: context_contract.TargetKind,
) Allocator.Error![]context_contract.ApplicableTarget {
    const targets = try alloc.alloc(context_contract.ApplicableTarget, 1);
    errdefer alloc.free(targets);
    targets[0] = .{
        .path = try alloc.dupe(u8, path),
        .kind = kind,
    };
    return targets;
}

fn freeApplicableTargets(alloc: Allocator, targets: []context_contract.ApplicableTarget) void {
    for (targets) |target| alloc.free(@constCast(target.path));
    if (targets.len > 0) alloc.free(targets);
}

fn testNoClassification(_: ?*anyopaque, _: Allocator, _: ToolCall) anyerror!?CallbackTerminal {
    return null;
}

const test_classifiers: Classifiers = .{
    .idempotent = testNoClassification,
    .validation = testNoClassification,
    .availability = testNoClassification,
};

test "advertised dynamic calls stay opaque while unsupported calls are terminal" {
    const alloc = std.testing.allocator;
    const empty_registry = tool_dispatch.Registry{ .tools = &.{} };
    const advertised = [_][]const u8{"mcp_filesystem"};

    var dynamic = try prepareReadyCall(alloc, .{
        .id = "dynamic",
        .name = "mcp_filesystem",
        .arguments_json = "{not parsed by Fx",
    }, .{
        .tool_registry = empty_registry,
        .workspace_root = "/tmp/workspace",
        .advertised_dynamic_tool_names = &advertised,
        .classifiers = test_classifiers,
    });
    defer dynamic.deinit(alloc);
    try std.testing.expectEqual(CandidateKind.advertised_dynamic, dynamic.candidate.kind);
    try std.testing.expectEqual(@as(usize, 0), dynamic.candidate.applicable_targets.len);
    try std.testing.expect(try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "dynamic", .name = "mcp_filesystem", .arguments_json = "{not parsed by Fx" },
        empty_registry,
        "/tmp/workspace",
        &dynamic.candidate,
    ));

    var unsupported = try prepareReadyCall(alloc, .{
        .id = "unsupported",
        .name = "not_advertised",
        .arguments_json = "{}",
    }, .{
        .tool_registry = empty_registry,
        .workspace_root = "/tmp/workspace",
        .classifiers = test_classifiers,
    });
    defer unsupported.deinit(alloc);
    try std.testing.expectEqual(TerminalKind.unsupported, unsupported.terminal.kind);
    try std.testing.expect(unsupported.terminal.model_output == null);
}

test "live deferred dynamic calls reach dispatch while true unknown calls stay terminal" {
    const Fixture = struct {
        fn classify(_: ?*anyopaque, _: Allocator, call: ToolCall) anyerror!bool {
            return std.mem.eql(u8, call.name, "mcp_reload_tool");
        }
    };
    var classifiers = test_classifiers;
    classifiers.deferred_dynamic = Fixture.classify;
    const config = Config{
        .tool_registry = .{ .tools = &.{} },
        .workspace_root = "/tmp/workspace",
        .classifiers = classifiers,
    };

    var deferred = try prepareReadyCall(std.testing.allocator, .{
        .id = "deferred",
        .name = "mcp_reload_tool",
        .arguments_json = "{}",
    }, config);
    defer deferred.deinit(std.testing.allocator);
    try std.testing.expectEqual(CandidateKind.deferred_dynamic, deferred.candidate.kind);

    var unknown = try prepareReadyCall(std.testing.allocator, .{
        .id = "unknown",
        .name = "unknown_tool",
        .arguments_json = "{}",
    }, config);
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqual(TerminalKind.unsupported, unknown.terminal.kind);
}

test "classifiers are ordered" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    const Fixture = struct {
        var idempotent_calls: usize = 0;
        var validation_calls: usize = 0;
        var availability_calls: usize = 0;

        fn idempotent(_: ?*anyopaque, callback_alloc: Allocator, call: ToolCall) anyerror!?CallbackTerminal {
            idempotent_calls += 1;
            if (!std.mem.eql(u8, call.name, "skill")) return null;
            return .{ .model_output = try callback_alloc.dupe(u8, "already loaded") };
        }

        fn validation(_: ?*anyopaque, _: Allocator, _: ToolCall) anyerror!?CallbackTerminal {
            validation_calls += 1;
            return null;
        }

        fn availability(_: ?*anyopaque, callback_alloc: Allocator, call: ToolCall) anyerror!?CallbackTerminal {
            availability_calls += 1;
            if (!std.mem.eql(u8, call.name, "web_search")) return null;
            return .{ .model_output = try callback_alloc.dupe(u8, "search unavailable"), .status = .failure };
        }
    };
    var test_web_search = builtin_tools.read_file;
    test_web_search.name = "web_search";
    test_web_search.model_schema.name = "web_search";
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.skill,
        test_web_search,
        builtin_tools.shell,
    };
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const classifiers: Classifiers = .{
        .idempotent = Fixture.idempotent,
        .validation = Fixture.validation,
        .availability = Fixture.availability,
    };

    Fixture.idempotent_calls = 0;
    Fixture.validation_calls = 0;
    Fixture.availability_calls = 0;
    var skipped = try prepareReadyCall(alloc, .{
        .id = "skill",
        .name = "skill",
        .arguments_json = "{\"name\":\"demo\",\"location\":\"/tmp/demo\"}",
    }, .{ .tool_registry = registry, .workspace_root = "/tmp/workspace", .classifiers = classifiers });
    defer skipped.deinit(alloc);
    try std.testing.expectEqual(TerminalKind.idempotent_skip, skipped.terminal.kind);
    try std.testing.expectEqual(@as(usize, 1), Fixture.idempotent_calls);
    try std.testing.expectEqual(@as(usize, 0), Fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 0), Fixture.availability_calls);

    var unavailable = try prepareReadyCall(alloc, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"fx context\"}",
    }, .{ .tool_registry = registry, .workspace_root = "/tmp/workspace", .classifiers = classifiers });
    defer unavailable.deinit(alloc);
    try std.testing.expectEqual(TerminalKind.availability_failure, unavailable.terminal.kind);
    try std.testing.expectEqual(@as(usize, 2), Fixture.idempotent_calls);
    try std.testing.expectEqual(@as(usize, 1), Fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 1), Fixture.availability_calls);
}

test "classifier validation failures remain terminal before execution" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const Fixture = struct {
        fn validation(_: ?*anyopaque, alloc: Allocator, _: ToolCall) anyerror!?CallbackTerminal {
            return .{
                .model_output = try alloc.dupe(u8, "invalid read arguments"),
                .status = .failure,
            };
        }
    };

    var result = try prepareReadyCall(std.testing.allocator, .{
        .id = "invalid-read",
        .name = "read_file",
        .arguments_json = "{}",
    }, .{
        .tool_registry = registry,
        .workspace_root = "/tmp/workspace",
        .classifiers = .{
            .idempotent = testNoClassification,
            .validation = Fixture.validation,
            .availability = testNoClassification,
        },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(TerminalKind.validation_failure, result.terminal.kind);
    try std.testing.expect(result.terminal.model_output.?.len > 0);
}

test "registered candidates expose only authoritative canonical targets" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/build/pkg");
    try tmp.dir.createDirPath(std.testing.io, "workspace/segment::scope");
    {
        var file = try tmp.dir.createFile(std.testing.io, "workspace/build/pkg/existing.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "old contents");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const existing_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace/build/pkg/existing.txt");
    defer alloc.free(existing_path);
    const build_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace/build");
    defer alloc.free(build_path);
    const delimiter_cwd_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace/segment::scope",
    );
    defer alloc.free(delimiter_cwd_path);
    const new_path = try std.fs.path.join(alloc, &.{ workspace, "build/pkg/new.txt" });
    defer alloc.free(new_path);
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.read_file,
        builtin_tools.write_file,
        builtin_tools.edit_file,
        builtin_tools.shell,
    };
    const registry = tool_dispatch.Registry{ .tools = &tools };

    var read = try prepareReadyCall(alloc, .{
        .id = "read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"build/pkg/existing.txt\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer read.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), read.candidate.applicable_targets.len);
    try std.testing.expectEqual(context_contract.TargetKind.file, read.candidate.applicable_targets[0].kind);
    try std.testing.expectEqualStrings(existing_path, read.candidate.applicable_targets[0].path);

    var missing = try prepareReadyCall(alloc, .{
        .id = "missing",
        .name = "read_file",
        .arguments_json = "{\"path\":\"build/pkg/missing.txt\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer missing.deinit(alloc);
    try std.testing.expectEqual(
        CandidateKind.legacy_target_resolution,
        missing.candidate.kind,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        missing.candidate.applicable_targets.len,
    );
    try std.testing.expect(try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "missing", .name = "read_file", .arguments_json = "{\"path\":\"build/pkg/missing.txt\"}" },
        registry,
        workspace,
        &missing.candidate,
    ));

    var command = try prepareReadyCall(alloc, .{
        .id = "command",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"cat unrelated/AGENTS.md\",\"cwd\":\"build\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer command.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), command.candidate.applicable_targets.len);
    try std.testing.expectEqual(context_contract.TargetKind.directory, command.candidate.applicable_targets[0].kind);
    try std.testing.expectEqualStrings(build_path, command.candidate.applicable_targets[0].path);

    var delimiter_command = try prepareReadyCall(alloc, .{
        .id = "delimiter-command",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"segment::scope\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer delimiter_command.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        delimiter_command.candidate.applicable_targets.len,
    );
    try std.testing.expectEqual(
        context_contract.TargetKind.directory,
        delimiter_command.candidate.applicable_targets[0].kind,
    );
    try std.testing.expectEqualStrings(
        delimiter_cwd_path,
        delimiter_command.candidate.applicable_targets[0].path,
    );

    var write = try prepareReadyCall(alloc, .{
        .id = "write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"build/pkg/new.txt\",\"content\":\"new contents\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer write.deinit(alloc);
    try std.testing.expectEqualStrings(new_path, write.candidate.applicable_targets[0].path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, new_path, .{}));

    var edit = try prepareReadyCall(alloc, .{
        .id = "edit",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"build/pkg/existing.txt\",\"old_string\":\"old\",\"new_string\":\"new\"}",
    }, .{ .tool_registry = registry, .workspace_root = workspace, .classifiers = test_classifiers });
    defer edit.deinit(alloc);
    try std.testing.expectEqualStrings(existing_path, edit.candidate.applicable_targets[0].path);
    var unchanged_file = try std.Io.Dir.openFileAbsolute(std.testing.io, existing_path, .{});
    defer unchanged_file.close(std.testing.io);
    const unchanged = try io_mod.readFileToEnd(alloc, &unchanged_file, 1024);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings("old contents", unchanged);
}

test "ordinary applicable target freshness detects retarget and resolution failure" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/old");
    try tmp.dir.createDirPath(std.testing.io, "workspace/new");
    {
        var old_file = try tmp.dir.createFile(std.testing.io, "workspace/old/input.txt", .{});
        defer old_file.close(std.testing.io);
        try old_file.writeStreamingAll(std.testing.io, "old");
        var new_file = try tmp.dir.createFile(std.testing.io, "workspace/new/input.txt", .{});
        defer new_file.close(std.testing.io);
        try new_file.writeStreamingAll(std.testing.io, "new");
    }
    try tmp.dir.symLink(std.testing.io, "old", "workspace/link", .{ .is_directory = true });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.read_file,
        builtin_tools.shell,
    };
    const config: Config = .{
        .tool_registry = .{ .tools = &tools },
        .workspace_root = workspace,
        .classifiers = test_classifiers,
    };

    var read = try prepareReadyCall(alloc, .{
        .id = "read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"link/input.txt\"}",
    }, config);
    defer read.deinit(alloc);
    var command = try prepareReadyCall(alloc, .{
        .id = "command",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"link\"}",
    }, config);
    defer command.deinit(alloc);
    try std.testing.expect(try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"link/input.txt\"}" },
        config.tool_registry,
        config.workspace_root,
        &read.candidate,
    ));
    try std.testing.expect(try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "command", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"link\"}" },
        config.tool_registry,
        config.workspace_root,
        &command.candidate,
    ));
    try tmp.dir.deleteFile(std.testing.io, "workspace/link");
    try tmp.dir.symLink(std.testing.io, "new", "workspace/link", .{ .is_directory = true });
    try std.testing.expect(!try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"link/input.txt\"}" },
        config.tool_registry,
        config.workspace_root,
        &read.candidate,
    ));
    try std.testing.expect(!try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "command", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"link\"}" },
        config.tool_registry,
        config.workspace_root,
        &command.candidate,
    ));
    var missing = try prepareReadyCall(alloc, .{
        .id = "missing",
        .name = "read_file",
        .arguments_json = "{\"path\":\"new/input.txt\"}",
    }, config);
    defer missing.deinit(alloc);
    try tmp.dir.deleteFile(std.testing.io, "workspace/new/input.txt");
    try std.testing.expect(!try ordinaryApplicableTargetsFresh(
        alloc,
        .{ .id = "missing", .name = "read_file", .arguments_json = "{\"path\":\"new/input.txt\"}" },
        config.tool_registry,
        config.workspace_root,
        &missing.candidate,
    ));
}

test "legacy ordinary applicable target freshness detects newly resolvable scope" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/nested");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const config: Config = .{
        .tool_registry = .{ .tools = &tools },
        .workspace_root = workspace,
        .classifiers = test_classifiers,
    };
    const call: ToolCall = .{
        .id = "missing",
        .name = "read_file",
        .arguments_json = "{\"path\":\"nested/later.txt\"}",
    };

    var missing = try prepareReadyCall(alloc, call, config);
    defer missing.deinit(alloc);
    try std.testing.expectEqual(
        CandidateKind.legacy_target_resolution,
        missing.candidate.kind,
    );
    try std.testing.expect(try ordinaryApplicableTargetsFresh(
        alloc,
        call,
        config.tool_registry,
        config.workspace_root,
        &missing.candidate,
    ));

    var file = try tmp.dir.createFile(std.testing.io, "workspace/nested/later.txt", .{});
    file.close(std.testing.io);
    try std.testing.expect(!try ordinaryApplicableTargetsFresh(
        alloc,
        call,
        config.tool_registry,
        config.workspace_root,
        &missing.candidate,
    ));
}

fn checkPreparationAllocationFailures(alloc: Allocator, workspace: []const u8) !void {
    const builtin_tools = @import("../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{builtin_tools.write_file};
    var result = try prepareReadyCall(alloc, .{
        .id = "write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"build/new.txt\",\"content\":\"contents\"}",
    }, .{
        .tool_registry = .{ .tools = &tools },
        .workspace_root = workspace,
        .classifiers = test_classifiers,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .candidate);
}

test "preparation cancellation and allocation failures clean owned state" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, prepareReadyCall(alloc, .{
        .id = "cancelled",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    }, .{
        .tool_registry = .{ .tools = &tools },
        .workspace_root = "/tmp/workspace",
        .cancel_flag = &cancelled,
        .classifiers = test_classifiers,
    }));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/build");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    try std.testing.checkAllAllocationFailures(
        alloc,
        checkPreparationAllocationFailures,
        .{workspace},
    );
}
