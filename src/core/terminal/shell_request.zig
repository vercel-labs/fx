//! The shell tool's model-facing argument contract.
//!
//! Models send one flat object: `command` to run something, or `session_id`
//! to check, type into, or stop a running command. `read` accepts that form
//! and every older shape fx still understands exactly (the `request` wrapper,
//! the wrapper holding a JSON string, `action` with the previous field names),
//! and produces one typed `Request`. `internalArguments` renders it in the
//! fields `shell.zig` decodes and permission admission reads, and
//! `modelArguments` renders it back in the flat form for conversation history.
//!
//! Everything here is pure except `system_locator`, which looks shell names up
//! on PATH. `read` never guesses: a call that could mean two things, or whose
//! text cannot be parsed, is a `Problem` that says what to send instead.
const std = @import("std");
const contracts = @import("contracts.zig");
const shell_resolver = @import("shell_resolver.zig");
const managed_contract = @import("../execution/managed_execution_contract.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Profile = enum { clean, user };

pub const Shell = struct {
    /// Absolute path of a shell `shell_resolver` supports.
    path: []const u8,
    /// Skip the shell's startup files.
    clean_start: bool = false,
};

pub const Run = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    shell: ?Shell = null,
    /// Only `.clean` is kept; with `shell` it becomes `clean_start`.
    profile: ?Profile = null,
    tty: bool = false,
    yield_time_ms: ?u32 = null,
    timeout_ms: ?u64 = null,
    reload: bool = false,
};

pub const Interact = struct {
    session_id: []const u8,
    chars: ?[]const u8 = null,
    yield_time_ms: ?u32 = null,
};

pub const Stop = struct {
    session_id: []const u8,
    force: bool = false,
};

pub const Request = union(enum) {
    run: Run,
    interact: Interact,
    stop: Stop,
};

/// Why a call cannot be read. The text is for the model and names the fix.
pub const Problem = []const u8;

pub const Outcome = union(enum) {
    request: Request,
    problem: Problem,
};

/// Resolves a bare shell name such as `bash` to an absolute path.
pub const ShellLocator = struct {
    context: ?*const anyopaque = null,
    find_fn: *const fn (context: ?*const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8,

    pub fn find(self: ShellLocator, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        return self.find_fn(self.context, arena, name);
    }
};

/// Never resolves a bare name; absolute paths still work. For reading calls
/// whose shell was already resolved, such as stored history.
pub const no_lookup_locator: ShellLocator = .{ .find_fn = findNothing };

fn findNothing(_: ?*const anyopaque, _: Allocator, _: []const u8) Allocator.Error!?[]const u8 {
    return null;
}

/// Looks bare shell names up on PATH, then in /bin and /usr/bin.
pub const system_locator: ShellLocator = .{ .find_fn = findOnPath };

fn findOnPath(_: ?*const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    const io = io_mod.getIo();
    const search = io_mod.getenv("PATH") orelse "";
    var dirs = std.mem.tokenizeScalar(u8, search, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(arena, &.{ dir, name });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true })) |_| return candidate else |_| {}
    }
    for ([_][]const u8{ "/bin", "/usr/bin" }) |dir| {
        const candidate = try std.fs.path.join(arena, &.{ dir, name });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true })) |_| return candidate else |_| {}
    }
    return null;
}

/// Larger argument text is not read; the bounded fields below fit well within it.
pub const max_arguments_bytes: usize = 256 * 1024;
const max_fields: usize = 32;

const run_fields = [_][]const u8{ "command", "cwd", "shell", "interactive", "tty", "timeout", "timeout_ms", "wait", "yield_time_ms", "profile", "reload" };
const interact_fields = [_][]const u8{ "session_id", "input", "chars", "wait", "yield_time_ms" };
const stop_fields = [_][]const u8{ "session_id", "stop", "force" };

/// Reads model arguments. Memory for the request and any problem text is
/// allocated in `arena`; slices may also point into `args_json`.
pub fn read(arena: Allocator, args_json: []const u8, locator: ShellLocator) Allocator.Error!Outcome {
    if (args_json.len > max_arguments_bytes) {
        return problem("The shell arguments are larger than 256 KiB. Write long content to a file with write_file and run a short command.");
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem("The shell arguments are not valid JSON. Escape quotes and backslashes inside strings, for example " ++ example_run ++ "."),
    };
    var fields = switch (try unwrap(arena, parsed)) {
        .fields => |object| object,
        .problem => |text| return problem(text),
    };
    elideAbsent(&fields);
    if (fields.count() > max_fields) return problem("The shell arguments have too many fields. Send only command, or only session_id with input or stop.");
    return decide(arena, fields, locator);
}

const example_run = "{\"command\": \"ls -la\"}";
const example_session = "{\"session_id\": \"shell-4\"}";

fn problem(text: []const u8) Outcome {
    return .{ .problem = text };
}

const Unwrapped = union(enum) {
    fields: std.json.ObjectMap,
    problem: Problem,
};

/// Removes one `request` wrapper, including a wrapper whose value is JSON text.
fn unwrap(arena: Allocator, value: std.json.Value) Allocator.Error!Unwrapped {
    if (value != .object) return .{ .problem = "The shell arguments must be one JSON object, for example " ++ example_run ++ "." };
    const outer = value.object;
    const wrapped = outer.get("request") orelse return .{ .fields = outer };
    const inner: std.json.ObjectMap = switch (wrapped) {
        .null => return .{ .fields = try without(arena, outer, "request") },
        .object => |object| object,
        .string => |text| blk: {
            if (isNullText(text)) return .{ .fields = try without(arena, outer, "request") };
            const decoded = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .problem = "request holds text that is not valid JSON: it looks cut off or has unescaped quotes. Send the fields directly, without request, for example " ++ example_run ++ "." },
            };
            if (decoded != .object) return .{ .problem = "request must hold the shell fields, for example " ++ example_run ++ "." };
            break :blk decoded.object;
        },
        else => return .{ .problem = "request must hold the shell fields, for example " ++ example_run ++ "." },
    };
    if (inner.contains("request")) return .{ .problem = "request is nested inside request. Send the fields directly, for example " ++ example_run ++ "." };
    var merged = try inner.clone(arena);
    var outer_fields = outer.iterator();
    while (outer_fields.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "request")) continue;
        if (merged.get(name)) |existing| {
            if (!jsonEqual(existing, entry.value_ptr.*)) {
                return .{ .problem = try std.fmt.allocPrint(arena, "{s} is set differently inside and outside request. Send each field once, without request.", .{boundedName(name)}) };
            }
            continue;
        }
        try merged.put(arena, name, entry.value_ptr.*);
    }
    return .{ .fields = merged };
}

fn without(arena: Allocator, object: std.json.ObjectMap, name: []const u8) Allocator.Error!std.json.ObjectMap {
    var copy = try object.clone(arena);
    _ = copy.orderedRemove(name);
    return copy;
}

fn isNullText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, &std.ascii.whitespace), "null");
}

/// Drops nulls and "null" placeholders, which some providers send for unused fields.
fn elideAbsent(fields: *std.json.ObjectMap) void {
    var index: usize = 0;
    while (index < fields.count()) {
        const value = fields.values()[index];
        if (value == .null or (value == .string and isNullText(value.string))) {
            fields.orderedRemoveAt(index);
        } else {
            index += 1;
        }
    }
}

fn decide(arena: Allocator, fields: std.json.ObjectMap, locator: ShellLocator) Allocator.Error!Outcome {
    if (try unknownField(arena, fields)) |text| return problem(text);
    if (fields.get("action")) |action_value| {
        const action_text = if (action_value == .string) action_value.string else "";
        const action = std.meta.stringToEnum(std.meta.Tag(Request), action_text) orelse
            return problem("action must be run, interact, or stop. It can be left out: command runs something, and session_id acts on a running command.");
        return switch (action) {
            .run => readRun(arena, fields, locator),
            .interact => readInteract(arena, fields),
            .stop => readStop(arena, fields),
        };
    }
    const has_command = switch (try stringField(fields, "command")) {
        .absent => false,
        .value => |text| text.len != 0,
        .wrong_type => return problem("command must be a string."),
    };
    const has_session = switch (try stringField(fields, "session_id")) {
        .absent => false,
        .value => |text| text.len != 0,
        .wrong_type => return problem("session_id must be a string."),
    };
    if (has_session) {
        const has_input = switch (try inputField(fields)) {
            .absent => false,
            .value => |text| text.len != 0,
            .wrong_type => return problem("input must be a string."),
        };
        const wants_stop = switch (boolField(fields, "stop")) {
            .wrong_type => return problem("stop must be true or false."),
            .absent => false,
            .value => |value| value,
        } or switch (boolField(fields, "force")) {
            .wrong_type => return problem("force must be true or false."),
            .absent => false,
            .value => |value| value,
        };
        if (has_input and wants_stop) return problem("Send input or stop for a session, not both.");
        if (has_input) return readInteract(arena, fields);
        if (wants_stop) return readStop(arena, fields);
        if (has_command) return problem("command and session_id were both sent. To run a new command, leave out session_id; to check the running one, leave out command, for example " ++ example_session ++ ".");
        return readInteract(arena, fields);
    }
    if (has_command) return readRun(arena, fields, locator);
    if (fields.get("command") != null) return problem("command is empty. Send the command to run, for example " ++ example_run ++ ".");
    return problem("Send command to run something, for example " ++ example_run ++ ", or session_id to check, type into, or stop a running command.");
}

/// A field fx does not know, carrying a real value, may hold intent fx would
/// lose by ignoring it. Default-like values are ignored.
fn unknownField(arena: Allocator, fields: std.json.ObjectMap) Allocator.Error!?Problem {
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "action") or contains(&run_fields, name) or
            contains(&interact_fields, name) or contains(&stop_fields, name)) continue;
        if (isDefaultLike(entry.value_ptr.*)) continue;
        return try std.fmt.allocPrint(
            arena,
            "{s} is not a shell field. Use command, shell, cwd, interactive, timeout, or wait to run something; session_id with input or stop for a running command.",
            .{boundedName(name)},
        );
    }
    return null;
}

fn isDefaultLike(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .bool => |flag| !flag,
        .string => |text| text.len == 0,
        .integer => |number| number == 0,
        .float => |number| number == 0,
        .number_string => |text| std.mem.eql(u8, text, "0"),
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
    };
}

fn readRun(arena: Allocator, fields: std.json.ObjectMap, locator: ShellLocator) Allocator.Error!Outcome {
    const command = switch (try stringField(fields, "command")) {
        .absent => return problem("command is required to run something, for example " ++ example_run ++ "."),
        .wrong_type => return problem("command must be a string."),
        .value => |text| text,
    };
    if (command.len == 0) return problem("command is empty. Send the command to run, for example " ++ example_run ++ ".");
    if (command.len > contracts.max_command_bytes) return problem("command is longer than 64 KiB. Write long scripts to a file with write_file and run the file.");

    var run: Run = .{ .command = command };
    switch (try stringField(fields, "cwd")) {
        .absent => {},
        .wrong_type => return problem("cwd must be a string."),
        .value => |text| run.cwd = if (text.len == 0) null else text,
    }
    switch (try stringField(fields, "profile")) {
        .absent => {},
        .wrong_type => return problem("profile must be clean or user."),
        .value => |text| {
            const profile = std.meta.stringToEnum(Profile, text) orelse return problem("profile must be clean or user.");
            if (profile == .clean) run.profile = .clean;
        },
    }
    if (fields.get("shell")) |value| {
        run.shell = switch (try readShell(arena, value, locator)) {
            .shell => |shell| shell,
            .problem => |text| return problem(text),
        };
    }
    if (run.shell) |*shell| {
        if (run.profile == .clean) shell.clean_start = true;
        run.profile = null;
    }
    run.tty = switch (try synonymBool(fields, "interactive", "tty")) {
        .value => |flag| flag,
        .absent => false,
        .problem => |text| return problem(text),
    };
    run.yield_time_ms = switch (try waitField(fields, managed_contract.max_yield_time_ms)) {
        .value => |ms| ms,
        .absent => null,
        .problem => |text| return problem(text),
    };
    run.timeout_ms = switch (try timeoutField(fields)) {
        .value => |ms| ms,
        .absent => null,
        .problem => |text| return problem(text),
    };
    run.reload = switch (boolField(fields, "reload")) {
        .value => |flag| flag,
        .absent => false,
        .wrong_type => return problem("reload must be true or false."),
    };
    return .{ .request = .{ .run = run } };
}

fn readInteract(arena: Allocator, fields: std.json.ObjectMap) Allocator.Error!Outcome {
    _ = arena;
    const session_id = switch (try stringField(fields, "session_id")) {
        .value => |text| if (text.len != 0) text else return problem("session_id is empty. Use the session_id a running command returned."),
        .absent => return problem("session_id is required to check or type into a running command. To start an interactive program, send command with interactive set to true."),
        .wrong_type => return problem("session_id must be a string."),
    };
    var interact: Interact = .{ .session_id = session_id };
    switch (try inputField(fields)) {
        .absent => {},
        .wrong_type => return problem("input must be a string."),
        .value => |text| {
            if (text.len > contracts.max_write_bytes) return problem("input is longer than 64 KiB. Send it in smaller parts.");
            interact.chars = if (text.len == 0) null else text;
        },
    }
    interact.yield_time_ms = switch (try waitField(fields, managed_contract.max_wait_ceiling_ms)) {
        .value => |ms| ms,
        .absent => null,
        .problem => |text| return problem(text),
    };
    return .{ .request = .{ .interact = interact } };
}

fn readStop(arena: Allocator, fields: std.json.ObjectMap) Allocator.Error!Outcome {
    _ = arena;
    const session_id = switch (try stringField(fields, "session_id")) {
        .value => |text| if (text.len != 0) text else return problem("session_id is empty. Use the session_id a running command returned."),
        .absent => return problem("session_id is required to stop a running command."),
        .wrong_type => return problem("session_id must be a string."),
    };
    return .{ .request = .{ .stop = .{
        .session_id = session_id,
        .force = switch (boolField(fields, "force")) {
            .value => |flag| flag,
            .absent => false,
            .wrong_type => return problem("force must be true or false."),
        },
    } } };
}

const ShellRead = union(enum) {
    shell: Shell,
    problem: Problem,
};

const unsupported_shell = "shell must be bash, zsh, sh, dash, or ksh, or an absolute path to one of them. Leave it out to use the user's shell.";

fn readShell(arena: Allocator, value: std.json.Value, locator: ShellLocator) Allocator.Error!ShellRead {
    var shell: Shell = switch (value) {
        .string => |text| .{ .path = text },
        // The previous form: {"kind": "executable", "path": ..., "clean_start": ...}.
        .object => |object| blk: {
            const path = object.get("path") orelse return .{ .problem = unsupported_shell };
            if (path != .string) return .{ .problem = unsupported_shell };
            const clean_start = if (object.get("clean_start")) |flag| switch (flag) {
                .bool => |b| b,
                .null => false,
                else => return .{ .problem = "shell.clean_start must be true or false." },
            } else false;
            break :blk .{ .path = path.string, .clean_start = clean_start };
        },
        else => return .{ .problem = unsupported_shell },
    };
    const name = std.mem.trim(u8, shell.path, &std.ascii.whitespace);
    if (name.len == 0 or !shell_resolver.isSupportedShell(name)) return .{ .problem = unsupported_shell };
    if (std.fs.path.isAbsolute(name)) {
        shell.path = name;
        return .{ .shell = shell };
    }
    if (std.mem.findScalar(u8, name, '/') != null) return .{ .problem = unsupported_shell };
    shell.path = try locator.find(arena, name) orelse
        return .{ .problem = try std.fmt.allocPrint(arena, "{s} was not found on PATH. Send its absolute path as shell, or leave shell out to use the user's shell.", .{name}) };
    return .{ .shell = shell };
}

const StringField = union(enum) {
    absent,
    wrong_type,
    value: []const u8,
};

fn stringField(fields: std.json.ObjectMap, name: []const u8) Allocator.Error!StringField {
    const value = fields.get(name) orelse return .absent;
    return switch (value) {
        .string => |text| .{ .value = text },
        else => .wrong_type,
    };
}

/// `input` is the flat name; `chars` is the previous one.
fn inputField(fields: std.json.ObjectMap) Allocator.Error!StringField {
    const input = try stringField(fields, "input");
    const chars = try stringField(fields, "chars");
    if (input == .wrong_type or chars == .wrong_type) return .wrong_type;
    if (input == .value and chars == .value and !std.mem.eql(u8, input.value, chars.value)) return .wrong_type;
    return if (input == .value) input else chars;
}

const BoolField = union(enum) {
    absent,
    wrong_type,
    value: bool,
};

fn boolField(fields: std.json.ObjectMap, name: []const u8) BoolField {
    const value = fields.get(name) orelse return .absent;
    return switch (value) {
        .bool => |flag| .{ .value = flag },
        .string => |text| if (std.mem.eql(u8, text, "true"))
            .{ .value = true }
        else if (std.mem.eql(u8, text, "false"))
            .{ .value = false }
        else
            .wrong_type,
        else => .wrong_type,
    };
}

fn Field(comptime T: type) type {
    return union(enum) {
        absent,
        value: T,
        problem: Problem,
    };
}

fn synonymBool(fields: std.json.ObjectMap, comptime name: []const u8, comptime previous: []const u8) Allocator.Error!Field(bool) {
    const current = boolField(fields, name);
    const old = boolField(fields, previous);
    if (current == .wrong_type or old == .wrong_type) return .{ .problem = name ++ " must be true or false." };
    if (current == .value and old == .value and current.value != old.value) return .{ .problem = name ++ " and " ++ previous ++ " disagree; send only " ++ name ++ "." };
    if (current == .value) return .{ .value = current.value };
    if (old == .value) return .{ .value = old.value };
    return .absent;
}

/// A JSON number, or a string holding one.
fn numberValue(value: std.json.Value) ?f64 {
    const parsed: f64 = switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string, .string => |text| std.fmt.parseFloat(f64, std.mem.trim(u8, text, &std.ascii.whitespace)) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(parsed)) parsed else null;
}

/// Milliseconds from `seconds`, rounded and clamped to [0, max_ms].
fn clampedMs(seconds: f64, max_ms: u32) u32 {
    const ms = @round(seconds * 1000);
    if (!(ms > 0)) return 0;
    if (ms >= @as(f64, @floatFromInt(max_ms))) return max_ms;
    return @intFromFloat(ms);
}

/// `wait` is seconds; `yield_time_ms` is the previous name in milliseconds.
/// Both clamp to the action's range instead of failing.
fn waitField(fields: std.json.ObjectMap, max_ms: u32) Allocator.Error!Field(u32) {
    const wait: ?u32 = if (fields.get("wait")) |value|
        clampedMs(numberValue(value) orelse return .{ .problem = "wait must be a number of seconds." }, max_ms)
    else
        null;
    const yield: ?u32 = if (fields.get("yield_time_ms")) |value|
        clampedMs((numberValue(value) orelse return .{ .problem = "yield_time_ms must be a number of milliseconds." }) / 1000, max_ms)
    else
        null;
    if (wait != null and yield != null and wait.? != yield.?) return .{ .problem = "wait and yield_time_ms disagree; send only wait, in seconds." };
    return if (wait orelse yield) |ms| .{ .value = ms } else .absent;
}

/// Longest deadline accepted; larger values clamp to it.
const max_timeout_ms: u64 = 7 * 24 * 60 * 60 * 1000;

/// `timeout` is seconds; `timeout_ms` is the previous name. Zero or less
/// means no deadline; anything above zero is at least 1 ms.
fn timeoutField(fields: std.json.ObjectMap) Allocator.Error!Field(?u64) {
    const timeout = if (fields.get("timeout")) |value|
        timeoutMs(numberValue(value) orelse return .{ .problem = "timeout must be a number of seconds." })
    else
        null;
    const previous = if (fields.get("timeout_ms")) |value|
        timeoutMs((numberValue(value) orelse return .{ .problem = "timeout_ms must be a number of milliseconds." }) / 1000)
    else
        null;
    if (fields.contains("timeout") and fields.contains("timeout_ms") and timeout != previous) {
        return .{ .problem = "timeout and timeout_ms disagree; send only timeout, in seconds." };
    }
    if (!fields.contains("timeout") and !fields.contains("timeout_ms")) return .absent;
    return .{ .value = if (fields.contains("timeout")) timeout else previous };
}

fn timeoutMs(seconds: f64) ?u64 {
    if (!(seconds > 0)) return null;
    const ms = @ceil(seconds * 1000);
    if (ms >= @as(f64, @floatFromInt(max_timeout_ms))) return max_timeout_ms;
    return @max(1, @as(u64, @intFromFloat(ms)));
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn boundedName(name: []const u8) []const u8 {
    return name[0..@min(name.len, 64)];
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| x.items.len == b.array.items.len and for (x.items, b.array.items) |left, right| {
            if (!jsonEqual(left, right)) break false;
        } else true,
        .object => |x| x.count() == b.object.count() and for (x.keys(), x.values()) |key, value| {
            const other = b.object.get(key) orelse break false;
            if (!jsonEqual(value, other)) break false;
        } else true,
    };
}

/// Renders `request` in the fields `shell.zig` decodes. Caller owns the result.
pub fn internalArguments(alloc: Allocator, request: Request) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeInternal(&json, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeInternal(json: *std.json.Stringify, request: Request) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("action");
    try json.write(@tagName(request));
    switch (request) {
        .run => |run| {
            try json.objectField("command");
            try json.write(run.command);
            if (run.cwd) |cwd| {
                try json.objectField("cwd");
                try json.write(cwd);
            }
            if (run.profile) |profile| {
                try json.objectField("profile");
                try json.write(@tagName(profile));
            }
            if (run.shell) |shell| {
                try json.objectField("shell");
                try json.beginObject();
                try json.objectField("kind");
                try json.write("executable");
                try json.objectField("path");
                try json.write(shell.path);
                if (shell.clean_start) {
                    try json.objectField("clean_start");
                    try json.write(true);
                }
                try json.endObject();
            }
            if (run.tty) {
                try json.objectField("tty");
                try json.write(true);
            }
            if (run.yield_time_ms) |ms| {
                try json.objectField("yield_time_ms");
                try json.write(ms);
            }
            if (run.timeout_ms) |ms| {
                try json.objectField("timeout_ms");
                try json.write(ms);
            }
            if (run.reload) {
                try json.objectField("reload");
                try json.write(true);
            }
        },
        .interact => |interact| {
            try json.objectField("session_id");
            try json.write(interact.session_id);
            if (interact.chars) |chars| {
                try json.objectField("chars");
                try json.write(chars);
            }
            if (interact.yield_time_ms) |ms| {
                try json.objectField("yield_time_ms");
                try json.write(ms);
            }
        },
        .stop => |stop| {
            try json.objectField("session_id");
            try json.write(stop.session_id);
            if (stop.force) {
                try json.objectField("force");
                try json.write(true);
            }
        },
    }
    try json.endObject();
}

/// Renders `request` in the flat form models send. Caller owns the result.
pub fn modelArguments(alloc: Allocator, request: Request) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeModel(&json, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeModel(json: *std.json.Stringify, request: Request) std.Io.Writer.Error!void {
    try json.beginObject();
    switch (request) {
        .run => |run| {
            try json.objectField("command");
            try json.write(run.command);
            if (run.shell) |shell| {
                try json.objectField("shell");
                try json.write(shell.path);
            }
            // The flat form has no clean-start field; the previous profile name keeps the call exact.
            if (run.profile == .clean or (run.shell != null and run.shell.?.clean_start)) {
                try json.objectField("profile");
                try json.write("clean");
            }
            if (run.cwd) |cwd| {
                try json.objectField("cwd");
                try json.write(cwd);
            }
            if (run.tty) {
                try json.objectField("interactive");
                try json.write(true);
            }
            if (run.timeout_ms) |ms| {
                try json.objectField("timeout");
                try writeSeconds(json, ms);
            }
            if (run.yield_time_ms) |ms| {
                try json.objectField("wait");
                try writeSeconds(json, ms);
            }
            if (run.reload) {
                try json.objectField("reload");
                try json.write(true);
            }
        },
        .interact => |interact| {
            try json.objectField("session_id");
            try json.write(interact.session_id);
            if (interact.chars) |chars| {
                try json.objectField("input");
                try json.write(chars);
            }
            if (interact.yield_time_ms) |ms| {
                try json.objectField("wait");
                try writeSeconds(json, ms);
            }
        },
        .stop => |stop| {
            try json.objectField("session_id");
            try json.write(stop.session_id);
            try json.objectField("stop");
            try json.write(true);
            if (stop.force) {
                try json.objectField("force");
                try json.write(true);
            }
        },
    }
    try json.endObject();
}

/// Seconds as a JSON number with at most millisecond precision: 30, 1.5, 0.001.
fn writeSeconds(json: *std.json.Stringify, ms: u64) std.Io.Writer.Error!void {
    var buffer: [32]u8 = undefined;
    const whole = ms / 1000;
    const fraction = ms % 1000;
    const text = if (fraction == 0)
        std.fmt.bufPrint(&buffer, "{d}", .{whole}) catch unreachable
    else blk: {
        const full = std.fmt.bufPrint(&buffer, "{d}.{d:0>3}", .{ whole, fraction }) catch unreachable;
        break :blk std.mem.trimEnd(u8, full, "0");
    };
    try json.print("{s}", .{text});
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

const FakeLocator = struct {
    fn find(_: ?*const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        if (std.mem.eql(u8, name, "zsh")) return null;
        return try std.fmt.allocPrint(arena, "/opt/fake/bin/{s}", .{name});
    }
    const locator: ShellLocator = .{ .find_fn = find };
};

// Mismatches go through std.testing, which prints both sides.
fn expectRequest(arena: Allocator, args: []const u8, expected_internal: []const u8) !void {
    const found = switch (try read(arena, args, FakeLocator.locator)) {
        .request => |request| try internalArguments(arena, request),
        .problem => |text| text,
    };
    try testing.expectEqualStrings(expected_internal, found);
}

fn expectProblem(arena: Allocator, args: []const u8, needle: []const u8) !void {
    switch (try read(arena, args, FakeLocator.locator)) {
        .request => |request| {
            try testing.expectEqualStrings("a problem", try internalArguments(arena, request));
            return error.TestUnexpectedResult;
        },
        .problem => |text| if (std.mem.find(u8, text, needle) == null) {
            try testing.expectEqualStrings(needle, text);
        },
    }
}

test "flat calls need no action" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectRequest(arena, "{\"command\":\"ls\"}", "{\"action\":\"run\",\"command\":\"ls\"}");
    try expectRequest(arena, "{\"command\":\"make\",\"cwd\":\"/repo\",\"timeout\":600,\"wait\":2}", "{\"action\":\"run\",\"command\":\"make\",\"cwd\":\"/repo\",\"yield_time_ms\":2000,\"timeout_ms\":600000}");
    try expectRequest(arena, "{\"command\":\"python3\",\"interactive\":true}", "{\"action\":\"run\",\"command\":\"python3\",\"tty\":true}");
    try expectRequest(arena, "{\"session_id\":\"shell-4\"}", "{\"action\":\"interact\",\"session_id\":\"shell-4\"}");
    try expectRequest(arena, "{\"session_id\":\"shell-4\",\"input\":\"q\"}", "{\"action\":\"interact\",\"session_id\":\"shell-4\",\"chars\":\"q\"}");
    try expectRequest(arena, "{\"session_id\":\"shell-4\",\"stop\":true}", "{\"action\":\"stop\",\"session_id\":\"shell-4\"}");
}

test "any supported shell is resolved without a terminal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectRequest(arena, "{\"command\":\"echo ${arr[0]}\",\"shell\":\"bash\"}", "{\"action\":\"run\",\"command\":\"echo ${arr[0]}\",\"shell\":{\"kind\":\"executable\",\"path\":\"/opt/fake/bin/bash\"}}");
    try expectRequest(arena, "{\"command\":\"./configure\",\"shell\":\"sh\"}", "{\"action\":\"run\",\"command\":\"./configure\",\"shell\":{\"kind\":\"executable\",\"path\":\"/opt/fake/bin/sh\"}}");
    try expectRequest(arena, "{\"command\":\"make\",\"shell\":\"/opt/homebrew/bin/bash\"}", "{\"action\":\"run\",\"command\":\"make\",\"shell\":{\"kind\":\"executable\",\"path\":\"/opt/homebrew/bin/bash\"}}");
    try expectRequest(arena, "{\"command\":\"make\",\"shell\":\"bash\",\"profile\":\"clean\"}", "{\"action\":\"run\",\"command\":\"make\",\"shell\":{\"kind\":\"executable\",\"path\":\"/opt/fake/bin/bash\",\"clean_start\":true}}");
    try expectProblem(arena, "{\"command\":\"ls\",\"shell\":\"zsh\"}", "zsh was not found on PATH");
    try expectProblem(arena, "{\"command\":\"print(1)\",\"shell\":\"python3\"}", "shell must be bash, zsh, sh, dash, or ksh");
    try expectProblem(arena, "{\"command\":\"ls\",\"shell\":\"bin/bash\"}", "shell must be bash");
}

test "older shapes read exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expected = "{\"action\":\"run\",\"command\":\"ls\"}";
    try expectRequest(arena, "{\"request\":{\"action\":\"run\",\"command\":\"ls\"}}", expected);
    try expectRequest(arena, "{\"request\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"ls\\\"}\"}", expected);
    try expectRequest(arena, "{\"action\":\"run\",\"command\":\"ls\"}", expected);
    try expectRequest(arena, "{\"request\":{\"command\":\"ls\"},\"action\":\"run\"}", expected);
    try expectRequest(arena, "{\"command\":\"ls\",\"yield_time_ms\":\"1000\",\"tty\":\"true\"}", "{\"action\":\"run\",\"command\":\"ls\",\"tty\":true,\"yield_time_ms\":1000}");
    try expectRequest(
        arena,
        "{\"action\":\"run\",\"command\":\"ls\",\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\"},\"tty\":true}",
        "{\"action\":\"run\",\"command\":\"ls\",\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\"},\"tty\":true}",
    );
    try expectRequest(arena, "{\"session_id\":\"s\",\"chars\":\"x\\n\",\"yield_time_ms\":1000}", "{\"action\":\"interact\",\"session_id\":\"s\",\"chars\":\"x\\n\",\"yield_time_ms\":1000}");
    try expectRequest(arena, "{\"session_id\":\"s\",\"force\":true}", "{\"action\":\"stop\",\"session_id\":\"s\",\"force\":true}");
}

test "fields that do not apply are ignored and values are clamped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Refinement 1: a new command wins over a stray stop.
    try expectRequest(arena, "{\"command\":\"ls\",\"stop\":true}", "{\"action\":\"run\",\"command\":\"ls\"}");
    // Refinement 2: a stray command is ignored when input or stop says what to do with the session.
    try expectRequest(arena, "{\"command\":\"ls\",\"session_id\":\"s\",\"input\":\"q\"}", "{\"action\":\"interact\",\"session_id\":\"s\",\"chars\":\"q\"}");
    try expectRequest(arena, "{\"command\":\"ls\",\"session_id\":\"s\",\"stop\":true}", "{\"action\":\"stop\",\"session_id\":\"s\"}");
    try expectRequest(arena, "{\"session_id\":\"s\",\"input\":\"q\",\"force\":false}", "{\"action\":\"interact\",\"session_id\":\"s\",\"chars\":\"q\"}");
    try expectRequest(arena, "{\"command\":\"ls\",\"profile\":\"user\",\"description\":\"\",\"chars\":null}", "{\"action\":\"run\",\"command\":\"ls\"}");
    try expectRequest(arena, "{\"command\":\"ls\",\"wait\":900}", "{\"action\":\"run\",\"command\":\"ls\",\"yield_time_ms\":30000}");
    try expectRequest(arena, "{\"command\":\"ls\",\"yield_time_ms\":120000}", "{\"action\":\"run\",\"command\":\"ls\",\"yield_time_ms\":30000}");
    try expectRequest(arena, "{\"session_id\":\"s\",\"wait\":600}", "{\"action\":\"interact\",\"session_id\":\"s\",\"yield_time_ms\":300000}");
    try expectRequest(arena, "{\"command\":\"ls\",\"wait\":-3,\"timeout\":0}", "{\"action\":\"run\",\"command\":\"ls\",\"yield_time_ms\":0}");
    try expectRequest(arena, "{\"command\":\"ls\",\"timeout\":0.0001}", "{\"action\":\"run\",\"command\":\"ls\",\"timeout_ms\":1}");
    try expectRequest(arena, "{\"command\":\"ls\",\"timeout_ms\":0}", "{\"action\":\"run\",\"command\":\"ls\"}");
}

test "calls that could mean two things or cannot be read are problems" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectProblem(arena, "{\"command\":\"ls\",\"session_id\":\"s\"}", "both sent");
    try expectProblem(arena, "{\"session_id\":\"s\",\"input\":\"q\",\"stop\":true}", "not both");
    try expectProblem(arena, "{\"request\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"ls\"}", "not valid JSON");
    try expectProblem(arena, "{\"action\":\"run\",\"command\":\"echo \"hi\"}", "not valid JSON");
    try expectProblem(arena, "{\"request\":{\"request\":{\"command\":\"ls\"}}}", "nested inside request");
    try expectProblem(arena, "{\"request\":{\"command\":\"ls\"},\"command\":\"pwd\"}", "inside and outside request");
    try expectProblem(arena, "{\"characters\":\"q\",\"session_id\":\"s\"}", "characters is not a shell field");
    try expectProblem(arena, "{\"action\":\"interact\",\"command\":\"python3\"}", "interactive set to true");
    try expectProblem(arena, "{\"action\":\"exec\",\"command\":\"ls\"}", "action must be run, interact, or stop");
    try expectProblem(arena, "{\"command\":\"\"}", "command is empty");
    try expectProblem(arena, "{}", "Send command");
    try expectProblem(arena, "[]", "one JSON object");
    try expectProblem(arena, "{\"command\":\"ls\",\"cwd\":5}", "cwd must be a string");
    try expectProblem(arena, "{\"command\":\"ls\",\"wait\":\"soon\"}", "wait must be a number");
    try expectProblem(arena, "{\"command\":\"ls\",\"wait\":2,\"yield_time_ms\":5000}", "disagree");
}

test "reading is idempotent and history round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const samples = [_][]const u8{
        "{\"command\":\"ls\"}",
        "{\"command\":\"make\",\"cwd\":\"/repo\",\"timeout\":1.5,\"wait\":0.25,\"reload\":true}",
        "{\"command\":\"echo hi\",\"shell\":\"bash\",\"interactive\":true}",
        "{\"command\":\"ls\",\"profile\":\"clean\"}",
        "{\"command\":\"ls\",\"shell\":\"sh\",\"profile\":\"clean\"}",
        "{\"session_id\":\"s\",\"input\":\"\\u0003\",\"wait\":300}",
        "{\"session_id\":\"s\"}",
        "{\"session_id\":\"s\",\"stop\":true,\"force\":true}",
        "{\"request\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"git log --format=\\\\\\\"%h %s\\\\\\\"\\\"}\"}",
    };
    for (samples) |sample| {
        const first = (try read(arena, sample, FakeLocator.locator)).request;
        const internal = try internalArguments(arena, first);
        // Law: reading the internal form gives the same request back.
        const again = (try read(arena, internal, no_lookup_locator)).request;
        try testing.expectEqualStrings(internal, try internalArguments(arena, again));
        // Law: the history form reads back to the same request.
        const model = try modelArguments(arena, first);
        const replayed = (try read(arena, model, no_lookup_locator)).request;
        try testing.expectEqualStrings(internal, try internalArguments(arena, replayed));
    }
}

test "history form is flat with seconds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = (try read(arena, "{\"request\":{\"action\":\"run\",\"command\":\"ls\",\"tty\":true,\"yield_time_ms\":1500,\"timeout_ms\":600000}}", FakeLocator.locator)).request;
    try testing.expectEqualStrings(
        "{\"command\":\"ls\",\"interactive\":true,\"timeout\":600,\"wait\":1.5}",
        try modelArguments(arena, request),
    );
    const stop = (try read(arena, "{\"action\":\"stop\",\"session_id\":\"s\"}", FakeLocator.locator)).request;
    try testing.expectEqualStrings("{\"session_id\":\"s\",\"stop\":true}", try modelArguments(arena, stop));
}

test "oversized arguments are not parsed" {
    const huge = try testing.allocator.alloc(u8, max_arguments_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect((try read(arena_state.allocator(), huge, FakeLocator.locator)) == .problem);
}
