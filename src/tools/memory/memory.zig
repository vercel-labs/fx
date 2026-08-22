const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_memory_store_bytes: usize = 1024 * 1024;

const MemoryStoreError = error{
    OutOfMemory,
    MemoryStoreMalformed,
    MemoryStoreTooLarge,
    MemoryStoreUnreadable,
};

pub const Input = struct {
    action: []u8,
    fact: ?[]u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.action);
        if (self.fact) |fact| alloc.free(fact);
        self.* = .{ .action = &.{}, .fact = null };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "memory arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "memory arguments must be an object") };
    }

    const action_value = parsed.value.object.get("action") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "memory field \"action\" is required") };
    };
    if (action_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "memory field \"action\" must be a string") };
    }

    const fact_value = parsed.value.object.get("fact");
    const fact: ?[]u8 = if (fact_value) |value|
        if (value == .string) try ctx.allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (fact) |owned| ctx.allocator.free(owned);

    const action = try ctx.allocator.dupe(u8, action_value.string);
    errdefer ctx.allocator.free(action);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .action = action, .fact = fact };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (!isSupportedAction(input.action)) {
        return try ctx.allocator.dupe(u8, "memory field \"action\" must be one of: save, list, clear");
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output = runMemory(ctx.allocator, input.action, input.fact) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MemoryStoreMalformed => return .{ .failure = try ctx.allocator.dupe(
            u8,
            "memory store is malformed; ~/.fx/memories.json was not modified. Repair or remove the file, then retry",
        ) },
        error.MemoryStoreTooLarge => return .{ .failure = try ctx.allocator.dupe(
            u8,
            "memory store exceeds the 1 MiB limit; ~/.fx/memories.json was not modified. Reduce or remove the file, then retry",
        ) },
        error.MemoryStoreUnreadable => return .{ .failure = try ctx.allocator.dupe(
            u8,
            "memory store could not be read; ~/.fx/memories.json was not modified. Check the file type and permissions, then retry",
        ) },
        error.MemoryClearFailed => return .{ .failure = try ctx.allocator.dupe(
            u8,
            "memory clear failed: saved memories were not removed; ensure ~/.fx/memories.json is a removable file and retry",
        ) },
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "memory failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn execute(arena: Allocator, args_json: []const u8) ![]u8 {
    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const action = try tool_args.requiredStringArg(args, "action");
    const fact = tool_args.optionalStringArg(args, "fact");
    return runMemory(arena, action, fact);
}

fn runMemory(alloc: Allocator, action: []const u8, fact: ?[]const u8) ![]u8 {
    if (!isSupportedAction(action)) return error.UnsupportedMemoryAction;

    const home = io_mod.getenv("HOME") orelse return std.fmt.allocPrint(alloc, "memory unavailable: HOME not set", .{});
    const memories_path = try profile_paths.memoriesPath(alloc, home);
    defer alloc.free(memories_path);

    if (std.mem.eql(u8, action, "save")) {
        const fact_value = fact orelse return std.fmt.allocPrint(alloc, "no fact provided", .{});
        var existing = try loadMemories(alloc, memories_path);
        defer freeMemories(alloc, &existing);

        for (existing.items) |memory| {
            if (std.mem.eql(u8, memory, fact_value)) return std.fmt.allocPrint(alloc, "remembered", .{});
        }

        try existing.append(alloc, try alloc.dupe(u8, fact_value));
        try saveMemories(alloc, memories_path, existing.items);
        return std.fmt.allocPrint(alloc, "remembered", .{});
    }

    if (std.mem.eql(u8, action, "list")) {
        var existing = try loadMemories(alloc, memories_path);
        defer freeMemories(alloc, &existing);

        if (existing.items.len == 0) return std.fmt.allocPrint(alloc, "No saved memories", .{});

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        for (existing.items) |memory| {
            try out.writer.print("- {s}\n", .{memory});
        }
        return try out.toOwnedSlice();
    }

    if (std.mem.eql(u8, action, "clear")) {
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), memories_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.MemoryClearFailed,
        };
        return std.fmt.allocPrint(alloc, "memories cleared", .{});
    }

    return error.UnsupportedMemoryAction;
}

fn isSupportedAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "save") or
        std.mem.eql(u8, action, "list") or
        std.mem.eql(u8, action, "clear");
}

fn loadMemories(alloc: Allocator, path: []const u8) MemoryStoreError!std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeMemories(alloc, &list);

    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return error.MemoryStoreUnreadable,
    };
    defer file.close(io_mod.getIo());
    const content = io_mod.readFileToEnd(alloc, &file, max_memory_store_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.MemoryStoreTooLarge,
        else => return error.MemoryStoreUnreadable,
    };
    defer alloc.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MemoryStoreMalformed,
    };
    defer parsed.deinit();

    if (parsed.value != .array) return error.MemoryStoreMalformed;
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.MemoryStoreMalformed;
        const owned = try alloc.dupe(u8, item.string);
        list.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    return list;
}

fn freeMemories(alloc: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |memory| alloc.free(memory);
    list.deinit(alloc);
}

fn saveMemories(alloc: Allocator, path: []const u8, memories: []const []u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), dir_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (memories, 0..) |memory, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeByte('\n');
        try out.writer.writeAll("  ");
        try std.json.Stringify.value(memory, .{}, &out.writer);
    }
    if (memories.len > 0) try out.writer.writeByte('\n');
    try out.writer.writeAll("]\n");
    const json = try out.toOwnedSlice();
    defer alloc.free(json);

    try io_mod.writeFileAtomic(alloc, path, json);
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return std.mem.eql(u8, erased.as(Input).action, "list");
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = tool_args.optionalStringArg(args, "action") orelse return null;
    if (!std.mem.eql(u8, action, "list")) return null;
    return .{
        .activity_kind = .read,
        .action_label = "Listing",
        .completed_action_label = "Listed",
        .label_arg_kind = .none,
        .label_arg_default = "memories",
    };
}

pub fn isIrreversible(erased: tool_dispatch.ToolInput) bool {
    return std.mem.eql(u8, erased.as(Input).action, "clear");
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectMemoryOutput(args_json: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const output = try execute(arena, args_json);
    try std.testing.expectEqualStrings(expected, output);
}

fn expectValidationFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |input| {
            defer input.deinit(alloc);
            const reason = (try validate(.{ .allocator = alloc }, input)) orelse {
                try std.testing.expect(false);
                return;
            };
            defer alloc.free(reason);
            try std.testing.expectEqualStrings(expected, reason);
        },
    }
}

fn setTestHome(home: ?[]const u8) !void {
    const map = try std.heap.c_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.c_allocator);
    if (home) |value| try map.put("HOME", value);
    io_mod.setEnvironMap(map);
}

test "memory owner rejects invalid JSON and action shape" {
    try expectDecodeFailure("{", "memory arguments must be valid JSON");
    try expectDecodeFailure("[]", "memory arguments must be an object");
    try expectDecodeFailure("{}", "memory field \"action\" is required");
    try expectDecodeFailure("{\"action\":1}", "memory field \"action\" must be a string");
}

test "memory owner rejects unsupported actions before execution" {
    try expectValidationFailure(
        "{\"action\":\"replace\",\"fact\":\"new value\"}",
        "memory field \"action\" must be one of: save, list, clear",
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnsupportedMemoryAction,
        execute(arena_state.allocator(), "{\"action\":\"replace\"}"),
    );
}

test "memory clear fails closed when state cannot be deleted" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/memories.json");
    {
        var survivor = try tmp.dir.createFile(
            io_mod.getIo(),
            "home/.fx/memories.json/must-survive.txt",
            .{},
        );
        survivor.close(io_mod.getIo());
    }

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try setTestHome(home);
    defer setTestHome(null) catch {};

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.MemoryClearFailed,
        execute(arena_state.allocator(), "{\"action\":\"clear\"}"),
    );

    var survivor = try tmp.dir.openFile(
        io_mod.getIo(),
        "home/.fx/memories.json/must-survive.txt",
        .{},
    );
    survivor.close(io_mod.getIo());
}

test "memory corrupt store fails closed and preserves original bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const corrupt_store = "[\"recoverable prior memory\",\n";
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "home/.fx/memories.json",
        .data = corrupt_store,
    });

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try setTestHome(home);
    defer setTestHome(null) catch {};

    var list_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer list_arena_state.deinit();
    try std.testing.expectError(
        error.MemoryStoreMalformed,
        execute(list_arena_state.allocator(), "{\"action\":\"list\"}"),
    );

    var save_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer save_arena_state.deinit();
    try std.testing.expectError(
        error.MemoryStoreMalformed,
        execute(save_arena_state.allocator(), "{\"action\":\"save\",\"fact\":\"replacement\"}"),
    );

    var file = try tmp.dir.openFile(io_mod.getIo(), "home/.fx/memories.json", .{});
    defer file.close(io_mod.getIo());
    const after = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(corrupt_store, after);
}

test "memory loader distinguishes missing oversized and unreadable stores" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const memories_path = try profile_paths.memoriesPath(alloc, home);
    defer alloc.free(memories_path);

    var missing = try loadMemories(alloc, memories_path);
    defer freeMemories(alloc, &missing);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);

    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), memories_path, .{});
        defer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), max_memory_store_bytes + 1);
    }
    try std.testing.expectError(
        error.MemoryStoreTooLarge,
        loadMemories(alloc, memories_path),
    );

    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), memories_path);
    try std.Io.Dir.createDirAbsolute(io_mod.getIo(), memories_path, .default_dir);
    try std.testing.expectError(
        error.MemoryStoreUnreadable,
        loadMemories(alloc, memories_path),
    );
}

test "memory owner preserves active output behavior" {
    const alloc = std.testing.allocator;
    try setTestHome(null);
    defer setTestHome(null) catch {};
    try expectMemoryOutput("{\"action\":\"list\"}", "memory unavailable: HOME not set");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try setTestHome(home);

    try expectMemoryOutput("{\"action\":\"list\"}", "No saved memories");
    try expectMemoryOutput("{\"action\":\"save\"}", "no fact provided");
    try expectMemoryOutput("{\"action\":\"save\",\"fact\":\"likes Zig\"}", "remembered");
    try expectMemoryOutput("{\"action\":\"save\",\"fact\":\"likes Zig\"}", "remembered");
    try expectMemoryOutput("{\"action\":\"list\"}", "- likes Zig\n");

    const memories_path = try profile_paths.memoriesPath(alloc, home);
    defer alloc.free(memories_path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), memories_path, .{});
    const content = blk: {
        defer file.close(io_mod.getIo());
        break :blk try io_mod.readFileToEnd(alloc, &file, 4096);
    };
    defer alloc.free(content);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("likes Zig", parsed.value.array.items[0].string);

    try expectMemoryOutput("{\"action\":\"clear\"}", "memories cleared");
    try expectMemoryOutput("{\"action\":\"list\"}", "No saved memories");
}
