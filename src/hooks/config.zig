//! Reads one hook file into owned hooks and diagnostics. A bad entry is
//! skipped with a diagnostic, and the rest of the file still loads.

const std = @import("std");
const event = @import("event.zig");
const answer = @import("answer.zig");
const match = @import("match.zig");
const limits = @import("limits.zig");

/// Where a hook comes from. Later layers run after earlier ones.
pub const Layer = enum { profile, workspace, project, claude_user, claude_project };

/// How fx starts a hook process.
pub const Command = union(enum) {
    /// Runs through `/bin/sh -c`.
    shell: []u8,
    /// Runs without a shell; the first item is the program.
    argv: [][]u8,
};

/// One hook from a file. Owns its memory.
pub const Hook = struct {
    id: []u8,
    event: event.EventName,
    matcher_text: []u8,
    matcher: match.Matcher,
    command: Command,
    timeout_ms: u32,
    on_failure: answer.OnFailure,
    layer: Layer,
    /// SHA-256 of what the hook does; fx stores trust by this hash.
    hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    /// Where the hook is in its file, such as "hooks.PreToolUse[0].hooks[1]".
    where: []u8,
};

/// One problem fx found in a file. Owns its memory.
const Diagnostic = struct { where: []u8, message: []u8 };

/// Everything fx read from one file. Owns its memory; free it with deinit.
pub const File = struct {
    hooks: []Hook = &.{},
    diagnostics: []Diagnostic = &.{},
    /// The profile file asked fx to read hooks from Claude Code settings files.
    claude_settings: bool = false,

    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        for (self.hooks) |*hook| freeHook(alloc, hook);
        for (self.diagnostics) |diagnostic| {
            alloc.free(diagnostic.where);
            alloc.free(diagnostic.message);
        }
        if (self.hooks.len > 0) alloc.free(self.hooks);
        if (self.diagnostics.len > 0) alloc.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const ParseOptions = struct {
    layer: Layer,
    /// For the profile file: also read `workspaces["<workspace_root>"].hooks`.
    workspace_root: ?[]const u8 = null,
    /// Report keys fx does not know. Off for Claude Code settings files, which hold other settings.
    report_unknown_keys: bool = true,
};

/// Parses `bytes`. The caller owns the result. Only running out of memory is an error;
/// every problem in the file becomes a diagnostic.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, options: ParseOptions) std.mem.Allocator.Error!File {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const message = try alloc.print("not valid JSON: {s}", .{@errorName(err)});
            defer alloc.free(message);
            return singleDiagnostic(alloc, "", message);
        },
    };
    defer parsed.deinit();

    var builder: Builder = .{ .alloc = alloc, .options = options };
    errdefer builder.deinit();

    try builder.readTop(parsed.value);
    return builder.finish();
}

/// How many bytes of a hook's hash its default id uses. Each byte takes two hex digits.
const default_id_hash_bytes = 6;

/// The default id of a hook: the first `default_id_hash_bytes` bytes of its hash, in lowercase hex.
fn defaultId(hash: [std.crypto.hash.sha2.Sha256.digest_length]u8) [default_id_hash_bytes * 2]u8 {
    const digits = "0123456789abcdef";
    var id: [default_id_hash_bytes * 2]u8 = undefined;
    for (hash[0..default_id_hash_bytes], 0..) |byte, index| {
        id[index * 2] = digits[byte >> 4];
        id[index * 2 + 1] = digits[byte & 0x0f];
    }
    return id;
}

/// Frees the memory of one hook.
fn freeHook(alloc: std.mem.Allocator, hook: *Hook) void {
    alloc.free(hook.id);
    alloc.free(hook.matcher_text);
    hook.matcher.deinit(alloc);
    freeCommand(alloc, hook.command);
    alloc.free(hook.where);
}

fn freeCommand(alloc: std.mem.Allocator, command: Command) void {
    switch (command) {
        .shell => |text| alloc.free(text),
        .argv => |items| {
            for (items) |item| alloc.free(item);
            if (items.len > 0) alloc.free(items);
        },
    }
}

/// A file holding one diagnostic. On error nothing is left allocated.
fn singleDiagnostic(alloc: std.mem.Allocator, where: []const u8, message: []const u8) std.mem.Allocator.Error!File {
    const owned_where = try alloc.dupe(u8, where);
    errdefer alloc.free(owned_where);
    const owned_message = try alloc.dupe(u8, message);
    errdefer alloc.free(owned_message);
    const diagnostics = try alloc.alloc(Diagnostic, 1);
    diagnostics[0] = .{ .where = owned_where, .message = owned_message };
    return .{ .diagnostics = diagnostics };
}

/// Keys of a handler that fx ignores without a diagnostic.
const ignored_handler_keys = [_][]const u8{
    "asyncRewake", "statusMessage", "shell",  "if",              "once",   "allowedEnvVars", "headers",
    "url",         "model",         "prompt", "continueOnBlock", "server", "tool",           "input",
};

/// Keys of a handler that fx reads.
const read_handler_keys = [_][]const u8{
    "type", "command", "args", "timeout", "on_failure", "onFailure", "async", "id",
};

/// The keys a hook group may hold besides its `hooks` list.
fn isKnownGroupKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "matcher") or std.mem.eql(u8, key, "hooks");
}

fn isKnownHandlerKey(key: []const u8) bool {
    for (read_handler_keys) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    for (ignored_handler_keys) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > limits.hook_id_bytes) return false;
    for (id) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Collects hooks and diagnostics while the file is read, and owns them until finish.
const Builder = struct {
    alloc: std.mem.Allocator,
    options: ParseOptions,
    hooks: std.ArrayList(Hook) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Whether the cap diagnostic was already added.
    capped: bool = false,
    /// Whether the profile file asked for Claude Code settings files.
    claude_settings: bool = false,

    fn deinit(self: *Builder) void {
        for (self.hooks.items) |*hook| freeHook(self.alloc, hook);
        self.hooks.deinit(self.alloc);
        for (self.diagnostics.items) |diagnostic| {
            self.alloc.free(diagnostic.where);
            self.alloc.free(diagnostic.message);
        }
        self.diagnostics.deinit(self.alloc);
    }

    fn finish(self: *Builder) std.mem.Allocator.Error!File {
        var file = File{};
        errdefer file.deinit(self.alloc);
        file.hooks = try self.hooks.toOwnedSlice(self.alloc);
        file.diagnostics = try self.diagnostics.toOwnedSlice(self.alloc);
        file.claude_settings = self.claude_settings;
        return file;
    }

    fn report(self: *Builder, where: []const u8, message: []const u8) std.mem.Allocator.Error!void {
        const owned_where = try self.alloc.dupe(u8, where);
        errdefer self.alloc.free(owned_where);
        const owned_message = try self.alloc.dupe(u8, message);
        errdefer self.alloc.free(owned_message);
        try self.diagnostics.append(self.alloc, .{ .where = owned_where, .message = owned_message });
    }

    /// Reports each key that `isKnown` does not accept, when the file asks for unknown keys to be reported.
    fn reportUnknownKeys(
        self: *Builder,
        where: []const u8,
        keys: []const []const u8,
        isKnown: *const fn ([]const u8) bool,
    ) std.mem.Allocator.Error!void {
        if (!self.options.report_unknown_keys) return;
        for (keys) |key| {
            if (isKnown(key)) continue;
            const key_path = try self.alloc.print("{s}.{s}", .{ where, key });
            defer self.alloc.free(key_path);
            try self.reportFormat(key_path, "unknown key \"{s}\"", .{key});
        }
    }

    fn reportFormat(self: *Builder, where: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const message = try self.alloc.print(fmt, args);
        defer self.alloc.free(message);
        try self.report(where, message);
    }

    fn readTop(self: *Builder, root: std.json.Value) std.mem.Allocator.Error!void {
        if (root != .object) {
            try self.report("", "the file must hold a JSON object");
            return;
        }
        if (root.object.get("hooks")) |hooks_value| {
            try self.readEvents(hooks_value, self.options.layer, "hooks");
        }
        if (root.object.get("workspaces")) |workspaces_value| {
            try self.readWorkspaces(workspaces_value);
        }
        if (root.object.get("claude_settings")) |claude_value| {
            if (self.options.layer == .profile) {
                if (claude_value != .bool) {
                    try self.report("claude_settings", "claude_settings must be true or false");
                } else {
                    self.claude_settings = claude_value.bool;
                }
            } else if (self.options.report_unknown_keys) {
                try self.report("claude_settings", "claude_settings is read only from the profile hook file");
            }
        }
        for (root.object.keys()) |key| {
            if (std.mem.eql(u8, key, "hooks") or std.mem.eql(u8, key, "workspaces") or
                std.mem.eql(u8, key, "claude_settings") or std.mem.eql(u8, key, "$schema")) continue;
            if (!self.options.report_unknown_keys) continue;
            try self.reportFormat(key, "unknown key \"{s}\"", .{key});
        }
    }

    fn readWorkspaces(self: *Builder, value: std.json.Value) std.mem.Allocator.Error!void {
        if (self.options.layer != .profile) {
            if (self.options.report_unknown_keys) {
                try self.report("workspaces", "workspaces is read only from the profile hook file");
            }
            return;
        }
        if (value != .object) {
            try self.report("workspaces", "workspaces must be an object");
            return;
        }
        const root = self.options.workspace_root orelse return;
        const entry = value.object.get(root) orelse return;
        if (entry != .object) {
            try self.report("workspaces", "a workspace must be an object");
            return;
        }

        const prefix = try self.alloc.print("workspaces[\"{s}\"].hooks", .{root});
        defer self.alloc.free(prefix);
        if (entry.object.get("hooks")) |hooks_value| {
            try self.readEvents(hooks_value, .workspace, prefix);
        }
        if (self.options.report_unknown_keys) {
            for (entry.object.keys()) |key| {
                if (std.mem.eql(u8, key, "hooks")) continue;
                const where = try self.alloc.print("workspaces[\"{s}\"].{s}", .{ root, key });
                defer self.alloc.free(where);
                try self.reportFormat(where, "unknown key \"{s}\"", .{key});
            }
        }
    }

    fn readEvents(
        self: *Builder,
        value: std.json.Value,
        layer: Layer,
        prefix: []const u8,
    ) std.mem.Allocator.Error!void {
        if (value != .object) {
            try self.report(prefix, "hooks must be an object");
            return;
        }
        for (value.object.keys(), value.object.values()) |key, event_value| {
            const where = try self.alloc.print("{s}.{s}", .{ prefix, key });
            defer self.alloc.free(where);

            const name = event.EventName.fromFileName(key) orelse {
                try self.reportFormat(where, "unknown event \"{s}\"", .{key});
                continue;
            };
            if (event_value != .array) {
                try self.reportFormat(where, "{s} must be a list", .{key});
                continue;
            }
            for (event_value.array.items, 0..) |group, index| {
                try self.readGroup(group, name, layer, where, index);
            }
        }
    }

    fn readGroup(
        self: *Builder,
        value: std.json.Value,
        name: event.EventName,
        layer: Layer,
        event_path: []const u8,
        index: usize,
    ) std.mem.Allocator.Error!void {
        const where = try self.alloc.print("{s}[{d}]", .{ event_path, index });
        defer self.alloc.free(where);

        if (value != .object) {
            try self.report(where, "a hook group must be an object");
            return;
        }

        var matcher_text: []const u8 = "";
        if (value.object.get("matcher")) |matcher_value| {
            if (matcher_value != .string) {
                try self.report(where, "matcher must be a string");
                return;
            }
            matcher_text = matcher_value.string;
        }
        if (name.capabilities().match == .none and matcher_text.len > 0 and !std.mem.eql(u8, matcher_text, "*")) {
            try self.reportFormat(where, "{s} has no matcher; this matcher is ignored", .{name.fileName()});
            matcher_text = "";
        }
        {
            const probe = try self.compileMatcher(where, matcher_text);
            if (probe == null) return;
            var compiled = probe.?;
            compiled.deinit(self.alloc);
        }

        const handlers = value.object.get("hooks") orelse {
            try self.report(where, "a hook group needs a \"hooks\" list");
            return;
        };
        if (handlers != .array) {
            try self.report(where, "a hook group needs a \"hooks\" list");
            return;
        }

        try self.reportUnknownKeys(where, value.object.keys(), &isKnownGroupKey);

        for (handlers.array.items, 0..) |handler, handler_index| {
            const handler_path = try self.alloc.print("{s}.hooks[{d}]", .{ where, handler_index });
            defer self.alloc.free(handler_path);
            try self.readHandler(handler, name, layer, matcher_text, handler_path);
        }
    }

    /// Compiles a matcher, or reports why it cannot be compiled. The caller owns a success.
    fn compileMatcher(self: *Builder, where: []const u8, matcher_text: []const u8) std.mem.Allocator.Error!?match.Matcher {
        if (match.compile(self.alloc, matcher_text)) |compiled| {
            return compiled;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMatcher => {
                try self.reportFormat(where, "matcher \"{s}\" is not valid", .{matcher_text});
                return null;
            },
            error.MatcherTooLong => {
                try self.reportFormat(where, "matcher is longer than {d} bytes", .{limits.matcher_bytes});
                return null;
            },
        }
    }

    fn readHandler(
        self: *Builder,
        value: std.json.Value,
        name: event.EventName,
        layer: Layer,
        matcher_text: []const u8,
        where: []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.hooks.items.len >= limits.hooks_per_file) {
            if (!self.capped) {
                self.capped = true;
                try self.reportFormat(where, "this file has more than {d} hooks; fx reads the first {d}", .{
                    limits.hooks_per_file,
                    limits.hooks_per_file,
                });
            }
            return;
        }

        if (value != .object) {
            try self.report(where, "a hook must be an object");
            return;
        }

        const type_value = value.object.get("type") orelse {
            try self.report(where, "type must be \"command\"");
            return;
        };
        if (type_value != .string) {
            try self.report(where, "type must be \"command\"");
            return;
        }
        const type_text = type_value.string;
        if (!std.mem.eql(u8, type_text, "command")) {
            if (std.mem.eql(u8, type_text, "http") or std.mem.eql(u8, type_text, "prompt") or
                std.mem.eql(u8, type_text, "agent") or std.mem.eql(u8, type_text, "mcp_tool"))
            {
                try self.reportFormat(where, "type \"{s}\" is not supported yet", .{type_text});
            } else {
                try self.report(where, "type must be \"command\"");
            }
            return;
        }

        var command: ?Command = null;
        defer {
            if (command) |held| freeCommand(self.alloc, held);
        }

        const command_value = value.object.get("command") orelse {
            try self.report(where, "command must be a non-empty string or a list of strings");
            return;
        };
        switch (command_value) {
            .string => |text| {
                if (text.len == 0) {
                    try self.report(where, "command must be a non-empty string or a list of strings");
                    return;
                }
                command = Command{ .shell = try self.alloc.dupe(u8, text) };
            },
            .array => |array| {
                const built = try self.stringList(array.items);
                if (built) |items| {
                    command = Command{ .argv = items };
                } else {
                    try self.report(where, "command must be a non-empty string or a list of strings");
                    return;
                }
            },
            else => {
                try self.report(where, "command must be a non-empty string or a list of strings");
                return;
            },
        }

        if (value.object.get("args")) |args_value| {
            if (args_value != .array) {
                try self.report(where, "args must be a list of strings");
                return;
            }
            for (args_value.array.items) |item| {
                switch (item) {
                    .string => {},
                    else => {
                        try self.report(where, "args must be a list of strings");
                        return;
                    },
                }
            }
            switch (command.?) {
                .argv => {
                    try self.report(where, "args needs a command string");
                    return;
                },
                .shell => |text| {
                    var list: std.ArrayList([]u8) = .empty;
                    errdefer {
                        for (list.items) |item| self.alloc.free(item);
                        list.deinit(self.alloc);
                    }
                    try self.appendCopy(&list, text);
                    for (args_value.array.items) |item| try self.appendCopy(&list, item.string);
                    const items = try list.toOwnedSlice(self.alloc);
                    freeCommand(self.alloc, command.?);
                    command = Command{ .argv = items };
                },
            }
        }

        var timeout_ms: u32 = limits.default_timeout_ms;
        if (value.object.get("timeout")) |timeout_value| {
            const seconds: f64 = switch (timeout_value) {
                .integer => |count| @floatFromInt(count),
                .float => |count| count,
                else => {
                    try self.report(where, "timeout must be a number of seconds above 0");
                    return;
                },
            };
            if (!(seconds > 0)) {
                try self.report(where, "timeout must be a number of seconds above 0");
                return;
            }
            const scaled = @round(seconds * @as(f64, ms_per_second));
            if (scaled > @as(f64, @floatFromInt(limits.max_timeout_ms))) {
                timeout_ms = limits.max_timeout_ms;
                try self.reportFormat(where, "timeout is above {d} seconds; fx uses {d}", .{
                    limits.max_timeout_ms / ms_per_second,
                    limits.max_timeout_ms / ms_per_second,
                });
            } else if (scaled < 1.0) {
                timeout_ms = 1;
            } else {
                timeout_ms = @intFromFloat(scaled);
            }
        }

        var on_failure: answer.OnFailure = .proceed;
        {
            var found: ?answer.OnFailure = null;
            for ([_][]const u8{ "on_failure", "onFailure" }) |key| {
                const raw = value.object.get(key) orelse continue;
                if (raw != .string) {
                    try self.report(where, "on_failure must be \"block\" or \"continue\"");
                    return;
                }
                const decided: answer.OnFailure = if (std.mem.eql(u8, raw.string, "block"))
                    .block
                else if (std.mem.eql(u8, raw.string, "continue") or std.mem.eql(u8, raw.string, "proceed"))
                    .proceed
                else {
                    try self.report(where, "on_failure must be \"block\" or \"continue\"");
                    return;
                };
                if (found) |earlier| {
                    if (earlier != decided) {
                        try self.report(where, "on_failure and onFailure disagree");
                        return;
                    }
                } else {
                    found = decided;
                }
            }
            if (found) |decided| on_failure = decided;
        }

        if (value.object.get("async")) |async_value| {
            switch (async_value) {
                .bool => |is_async| {
                    if (is_async) {
                        try self.report(where, "async hooks are not supported yet; this hook runs and fx waits for it");
                    }
                },
                else => {},
            }
        }

        var explicit_id: ?[]const u8 = null;
        if (value.object.get("id")) |id_value| {
            if (id_value != .string or !validId(id_value.string)) {
                try self.reportFormat(where, "id must be 1 to {d} letters, digits, dots, dashes, or underscores", .{limits.hook_id_bytes});
                return;
            }
            explicit_id = id_value.string;
        }

        try self.reportUnknownKeys(where, value.object.keys(), &isKnownHandlerKey);

        const hash = hashOf(name, matcher_text, command.?, timeout_ms, on_failure);

        var id_owned: ?[]u8 = null;
        var text_owned: ?[]u8 = null;
        var where_owned: ?[]u8 = null;
        var hook_matcher: ?match.Matcher = null;
        defer {
            if (id_owned) |text| self.alloc.free(text);
            if (text_owned) |text| self.alloc.free(text);
            if (where_owned) |text| self.alloc.free(text);
            if (hook_matcher) |*held| held.deinit(self.alloc);
        }

        const id_default = defaultId(hash);
        id_owned = if (explicit_id) |given|
            try self.alloc.dupe(u8, given)
        else
            try self.alloc.dupe(u8, &id_default);

        for (self.hooks.items) |existing| {
            if (!std.mem.eql(u8, existing.id, id_owned.?)) continue;
            try self.reportFormat(where, "id \"{s}\" is used twice; this hook is skipped", .{id_owned.?});
            return;
        }

        hook_matcher = try self.compileMatcher(where, matcher_text);
        if (hook_matcher == null) return;
        text_owned = try self.alloc.dupe(u8, matcher_text);
        where_owned = try self.alloc.dupe(u8, where);

        try self.hooks.append(self.alloc, .{
            .id = id_owned.?,
            .event = name,
            .matcher_text = text_owned.?,
            .matcher = hook_matcher.?,
            .command = command.?,
            .timeout_ms = timeout_ms,
            .on_failure = on_failure,
            .layer = layer,
            .hash = hash,
            .where = where_owned.?,
        });
        id_owned = null;
        text_owned = null;
        where_owned = null;
        hook_matcher = null;
        command = null;
    }

    /// Copies a list of non-empty strings, or returns null when the list is not that.
    fn stringList(self: *Builder, items: []const std.json.Value) std.mem.Allocator.Error!?[][]u8 {
        if (items.len == 0) return null;
        for (items) |item| {
            switch (item) {
                .string => |text| if (text.len == 0) return null,
                else => return null,
            }
        }
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |text| self.alloc.free(text);
            list.deinit(self.alloc);
        }
        for (items) |item| try self.appendCopy(&list, item.string);
        return try list.toOwnedSlice(self.alloc);
    }

    fn appendCopy(self: *Builder, list: *std.ArrayList([]u8), text: []const u8) std.mem.Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, text);
        list.append(self.alloc, copy) catch |err| {
            self.alloc.free(copy);
            return err;
        };
    }
};

/// The hash of what a hook does, without its id and layer.
/// Milliseconds in a second. A hook file gives its timeout in seconds, and the engine counts in
/// milliseconds. (The name `std.time.ms_per_s` is not used here: the hooks engine may not name std.time.)
const ms_per_second = 1000;

/// The most decimal digits a u32 can take: 4294967295 has ten.
const max_u32_digits = 10;

fn hashOf(
    name: event.EventName,
    matcher_text: []const u8,
    command: Command,
    timeout_ms: u32,
    on_failure: answer.OnFailure,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const zero = [_]u8{0};

    hasher.update(name.fileName());
    hasher.update(&zero);
    hasher.update(matcher_text);
    hasher.update(&zero);
    switch (command) {
        .shell => |text| {
            hasher.update("shell");
            hasher.update(&zero);
            hasher.update(text);
            hasher.update(&zero);
        },
        .argv => |items| {
            hasher.update("argv");
            hasher.update(&zero);
            for (items) |item| {
                hasher.update(item);
                hasher.update(&zero);
            }
        },
    }
    var timeout_text: [max_u32_digits]u8 = undefined;
    const timeout_slice = std.mem.print(&timeout_text, "{d}", .{timeout_ms}) catch unreachable;
    hasher.update(timeout_slice);
    hasher.update(&zero);
    hasher.update(if (on_failure == .block) "block" else "proceed");

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

fn expectHex(text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return error.NotLowercaseHex,
        }
    }
}

test "a minimal file loads one hook" {
    const alloc = std.testing.allocator;
    const text =
        \\{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./check.sh"}]}]}}
    ;
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);

    const hook = file.hooks[0];
    try std.testing.expectEqual(event.EventName.pre_tool_use, hook.event);
    try std.testing.expectEqualStrings("Bash", hook.matcher_text);
    try std.testing.expectEqualStrings("./check.sh", hook.command.shell);
    try std.testing.expectEqual(@as(u32, 60000), hook.timeout_ms);
    try std.testing.expectEqual(answer.OnFailure.proceed, hook.on_failure);
    try std.testing.expectEqual(Layer.profile, hook.layer);
    try std.testing.expectEqual(@as(usize, 12), hook.id.len);
    try expectHex(hook.id);
    const expected_id = defaultId(hook.hash);
    try std.testing.expectEqualStrings(&expected_id, hook.id);
    try std.testing.expectEqualStrings("hooks.PreToolUse[0].hooks[0]", hook.where);
    try std.testing.expect(hook.matcher.matchesTool("shell"));
}

test "a command may be a list or a string with args" {
    const alloc = std.testing.allocator;

    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"/bin/echo\",\"hi\"]}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
        const items = file.hooks[0].command.argv;
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("/bin/echo", items[0]);
        try std.testing.expectEqualStrings("hi", items[1]);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/bin/echo\",\"args\":[\"a\",\"b\"]}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
        const items = file.hooks[0].command.argv;
        try std.testing.expectEqual(@as(usize, 3), items.len);
        try std.testing.expectEqualStrings("/bin/echo", items[0]);
        try std.testing.expectEqualStrings("a", items[1]);
        try std.testing.expectEqualStrings("b", items[2]);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"/bin/echo\"],\"args\":[\"a\"]}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("args needs a command string", file.diagnostics[0].message);
    }
}

test "SubagentStart has no matcher, so a named one is reported and ignored" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"SubagentStart\":[{\"matcher\":\"reviewer\",\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqualStrings("", file.hooks[0].matcher_text);
    try std.testing.expect(file.hooks[0].matcher.matches("anything"));
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("SubagentStart has no matcher; this matcher is ignored", file.diagnostics[0].message);
}

test "SubagentStop has no matcher, so a named one is reported and ignored" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"SubagentStop\":[{\"matcher\":\"reviewer\",\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqualStrings("", file.hooks[0].matcher_text);
    try std.testing.expect(file.hooks[0].matcher.matches("anything"));
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("SubagentStop has no matcher; this matcher is ignored", file.diagnostics[0].message);
}

test "a star or empty matcher on a subagent event is not reported" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"SubagentStart\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]},{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"d\"}]}],\"SubagentStop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"e\"}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
}

test "a timeout becomes milliseconds" {
    const alloc = std.testing.allocator;

    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":5}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 5000), file.hooks[0].timeout_ms);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":0.5}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 500), file.hooks[0].timeout_ms);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":900}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
        try std.testing.expectEqual(@as(u32, 600000), file.hooks[0].timeout_ms);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":0}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("timeout must be a number of seconds above 0", file.diagnostics[0].message);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":\"5\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("timeout must be a number of seconds above 0", file.diagnostics[0].message);
    }
}

test "on_failure and onFailure agree or the hook is skipped" {
    const alloc = std.testing.allocator;

    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"on_failure\":\"block\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(answer.OnFailure.block, file.hooks[0].on_failure);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"onFailure\":\"continue\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(answer.OnFailure.proceed, file.hooks[0].on_failure);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"on_failure\":\"maybe\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("on_failure must be \"block\" or \"continue\"", file.diagnostics[0].message);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"on_failure\":\"block\",\"onFailure\":\"continue\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("on_failure and onFailure disagree", file.diagnostics[0].message);
    }
}

test "an unknown event is reported" {
    const alloc = std.testing.allocator;

    {
        const text = "{\"hooks\":{\"PreToolUsee\":[]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("hooks.PreToolUsee", file.diagnostics[0].where);
        try std.testing.expectEqualStrings("unknown event \"PreToolUsee\"", file.diagnostics[0].message);
    }
    {
        const text = "{\"hooks\":{\"TurnEnd\":[]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    }
}

test "a hook type must be a command" {
    const alloc = std.testing.allocator;

    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"http\",\"command\":\"c\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("type \"http\" is not supported yet", file.diagnostics[0].message);
    }
    {
        const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"c\"}]}]}}";
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("type must be \"command\"", file.diagnostics[0].message);
    }
}

test "an invalid matcher skips the group" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"(\",\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("matcher \"(\" is not valid", file.diagnostics[0].message);
}

test "a matcher on an event without one is ignored" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"Stop\":[{\"matcher\":\"x\",\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqualStrings("", file.hooks[0].matcher_text);
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("Stop has no matcher; this matcher is ignored", file.diagnostics[0].message);
}

test "a file that is not JSON is reported" {
    const alloc = std.testing.allocator;

    {
        var file = try parse(alloc, "{", .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expect(std.mem.startsWith(u8, file.diagnostics[0].message, "not valid JSON: "));
    }
    {
        var file = try parse(alloc, "[]", .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("the file must hold a JSON object", file.diagnostics[0].message);
    }
}

test "unknown keys are reported only when asked" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{},\"foo\":1}";

    {
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("unknown key \"foo\"", file.diagnostics[0].message);
    }
    {
        var file = try parse(alloc, text, .{ .layer = .profile, .report_unknown_keys = false });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
    }
}

test "the profile file reads the workspace hooks for its root" {
    const alloc = std.testing.allocator;
    const text =
        \\{"workspaces":{"/Users/example/proj":{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"a"}]}]}},"/Users/example/other":{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"b"}]}]}}},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"top"}]}]}}
    ;

    {
        var file = try parse(alloc, text, .{ .layer = .profile, .workspace_root = "/Users/example/proj" });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
        try std.testing.expectEqual(event.EventName.pre_tool_use, file.hooks[0].event);
        try std.testing.expectEqual(Layer.profile, file.hooks[0].layer);
        try std.testing.expectEqual(event.EventName.stop, file.hooks[1].event);
        try std.testing.expectEqual(Layer.workspace, file.hooks[1].layer);
        try std.testing.expectEqualStrings("a", file.hooks[1].command.shell);
        try std.testing.expect(std.mem.startsWith(u8, file.hooks[1].where, "workspaces[\"/Users/example/proj\"].hooks"));
    }
    {
        var file = try parse(alloc, text, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    }
}

test "workspaces is read only from the profile file" {
    const alloc = std.testing.allocator;
    const text = "{\"workspaces\":{\"/Users/example/proj\":{\"hooks\":{}}}}";
    var file = try parse(alloc, text, .{ .layer = .project, .workspace_root = "/Users/example/proj" });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("workspaces is read only from the profile hook file", file.diagnostics[0].message);
}

test "hook ids come from the hash or from the file" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";

    var first = try parse(alloc, text, .{ .layer = .profile });
    defer first.deinit(alloc);
    var second = try parse(alloc, text, .{ .layer = .profile });
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings(first.hooks[0].id, second.hooks[0].id);

    {
        const other = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"d\"}]}]}}";
        var file = try parse(alloc, other, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expect(!std.mem.eql(u8, first.hooks[0].id, file.hooks[0].id));
    }
    {
        const named = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"id\":\"my-guard\"}]}]}}";
        var file = try parse(alloc, named, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqualStrings("my-guard", file.hooks[0].id);
    }
    {
        const bad = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"id\":\"bad id!\"}]}]}}";
        var file = try parse(alloc, bad, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), file.hooks.len);
        try std.testing.expectEqualStrings("id must be 1 to 128 letters, digits, dots, dashes, or underscores", file.diagnostics[0].message);
    }
    {
        const twice = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"id\":\"dup\"},{\"type\":\"command\",\"command\":\"d\",\"id\":\"dup\"}]}]}}";
        var file = try parse(alloc, twice, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("id \"dup\" is used twice; this hook is skipped", file.diagnostics[0].message);
    }
    {
        const identical = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\"},{\"type\":\"command\",\"command\":\"c\"}]}]}}";
        var file = try parse(alloc, identical, .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expect(std.mem.startsWith(u8, file.diagnostics[0].message, "id \""));
        try std.testing.expect(std.mem.endsWith(u8, file.diagnostics[0].message, "\" is used twice; this hook is skipped"));
    }
}

test "the hash covers the timeout but not the id" {
    const alloc = std.testing.allocator;
    const base = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\"}]}]}}";
    const timed = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"timeout\":5}]}]}}";
    const named = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"id\":\"mine\"}]}]}}";

    var base_file = try parse(alloc, base, .{ .layer = .profile });
    defer base_file.deinit(alloc);
    var timed_file = try parse(alloc, timed, .{ .layer = .profile });
    defer timed_file.deinit(alloc);
    var named_file = try parse(alloc, named, .{ .layer = .profile });
    defer named_file.deinit(alloc);

    try std.testing.expect(!std.mem.eql(u8, &base_file.hooks[0].hash, &timed_file.hooks[0].hash));
    try std.testing.expectEqualSlices(u8, &base_file.hooks[0].hash, &named_file.hooks[0].hash);
}

test "a Claude Code settings file loads its command hooks" {
    const alloc = std.testing.allocator;
    const text =
        \\{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"npx prettier --write","statusMessage":"fmt"}]}]}}
    ;
    var file = try parse(alloc, text, .{ .layer = .claude_user, .report_unknown_keys = false });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
    try std.testing.expect(file.hooks[0].matcher.matchesTool("edit_file"));
}

test "an async hook loads with a diagnostic" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"c\",\"async\":true}]}]}}";
    var file = try parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), file.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("async hooks are not supported yet; this hook runs and fx waits for it", file.diagnostics[0].message);
}

test "the number of hooks in a file is capped" {
    const alloc = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);

    try text.appendSlice(alloc, "{\"hooks\":{\"PreToolUse\":[");
    var index: usize = 0;
    while (index <= limits.hooks_per_file) : (index += 1) {
        if (index > 0) try text.append(alloc, ',');
        const piece = try alloc.print(
            "{{\"hooks\":[{{\"type\":\"command\",\"command\":\"c{d}\",\"id\":\"h{d}\"}}]}}",
            .{ index, index },
        );
        defer alloc.free(piece);
        try text.appendSlice(alloc, piece);
    }
    try text.appendSlice(alloc, "]}}");

    var file = try parse(alloc, text.items, .{ .layer = .profile });
    defer file.deinit(alloc);

    try std.testing.expectEqual(limits.hooks_per_file, file.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
    try std.testing.expectEqualStrings("this file has more than 256 hooks; fx reads the first 256", file.diagnostics[0].message);
}

test "the profile file may ask for Claude Code settings" {
    const alloc = std.testing.allocator;

    {
        var file = try parse(alloc, "{\"claude_settings\":true,\"hooks\":{}}", .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expect(file.claude_settings);
        try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
    }
    {
        var file = try parse(alloc, "{\"claude_settings\":\"yes\"}", .{ .layer = .profile });
        defer file.deinit(alloc);
        try std.testing.expect(!file.claude_settings);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("claude_settings", file.diagnostics[0].where);
        try std.testing.expectEqualStrings("claude_settings must be true or false", file.diagnostics[0].message);
    }
    {
        var file = try parse(alloc, "{\"claude_settings\":true}", .{ .layer = .project });
        defer file.deinit(alloc);
        try std.testing.expect(!file.claude_settings);
        try std.testing.expectEqual(@as(usize, 1), file.diagnostics.len);
        try std.testing.expectEqualStrings("claude_settings", file.diagnostics[0].where);
        try std.testing.expectEqualStrings("claude_settings is read only from the profile hook file", file.diagnostics[0].message);
    }
    {
        var file = try parse(alloc, "{\"claude_settings\":true}", .{ .layer = .claude_user, .report_unknown_keys = false });
        defer file.deinit(alloc);
        try std.testing.expect(!file.claude_settings);
        try std.testing.expectEqual(@as(usize, 0), file.diagnostics.len);
    }
}
