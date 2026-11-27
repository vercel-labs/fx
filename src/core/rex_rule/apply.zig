//! Carries out one `plan.Step` for the Rex resume rule: the edits to Rex's
//! init.lua and fx.lua, fx's own state file, and every call to Rex. Rex is
//! reached only through `Rex`, so tests run with a fake and no process.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const plan = @import("plan.zig");
const records = @import("records.zig");

pub const Outcome = enum { none, added, verified, removed, skipped, rolled_back };

/// Talks to Rex. Block 2b gives the real one (it runs the `rex` command); tests pass a fake.
pub const Rex = struct {
    ctx: *anyopaque,
    /// Rex's records answer for this terminal, written into `out`, or null on any failure.
    records: *const fn (ctx: *anyopaque, out: []u8) ?[]const u8,
    /// True when `rex config check <init_path>` exits 0.
    check: *const fn (ctx: *anyopaque, init_path: []const u8) bool,
    /// True when `rex config reload` exits 0.
    reload: *const fn (ctx: *anyopaque) bool,
    /// Waits `ms` milliseconds; false when the attempt was cancelled.
    pause: *const fn (ctx: *anyopaque, ms: u64) bool,
};

pub const Paths = struct {
    config_dir: []const u8, // Rex's config folder, absolute (holds init.lua)
    state_dir: []const u8, // fx's own folder for this feature: <fx home>/rex, absolute
    sessions_dir: []const u8, // real path of fx's sessions/v2 folder
    exe_path: ?[]const u8, // fx's own absolute path, or null
};

const record_wait_attempts: usize = 10;
const record_wait_ms: u64 = 200;
const max_small_file_bytes: usize = 64 * 1024;

const trace_scope = "rex_rule";
const init_name = "init.lua";
const fx_lua_name = "fx.lua";
const lock_name = "lock";
const state_name = "state.json";
const backup_name_prefix = "init.lua.backup-";
const added_key = "added";
const gave_up_key = "gave_up";
const created_init_key = "created_init";
const owner_write_mode = 0o200;
const private_file_mode = std.Io.File.Permissions.fromMode(0o600);
const private_dir_mode = std.Io.File.Permissions.fromMode(0o700);

pub fn run(alloc: std.mem.Allocator, rex: Rex, paths: Paths, pid: u32, setting_on: bool) Outcome {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    return runInArena(arena.allocator(), rex, paths, pid, setting_on) catch |err| {
        return traced(.skipped, @errorName(err));
    };
}

fn runInArena(a: std.mem.Allocator, rex: Rex, paths: Paths, pid: u32, setting_on: bool) !Outcome {
    const io = io_mod.getIo();
    const files = try Files.init(a, paths);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, paths.state_dir, private_dir_mode);

    var lock_file = try std.Io.Dir.cwd().createFile(io, files.lock_path, .{ .truncate = false, .permissions = private_file_mode });
    defer lock_file.close(io);
    const locked = try lock_file.tryLock(io, .exclusive);
    if (!locked) return traced(.skipped, "lock busy");
    defer lock_file.unlock(io);

    const state = try readState(a, files.state_path);
    if (setting_on and contains(state.gave_up, files.config_dir)) {
        return traced(.skipped, "gave up on this config folder");
    }

    var record: plan.RecordState = .none;
    if (setting_on) {
        record = (try waitForRecord(a, rex, pid, isDecided)) orelse {
            return traced(.none, "cancelled while Rex answered");
        };
    }
    const observed = try observe(a, rex, files);
    const step = plan.decide(.{
        .setting_on = setting_on,
        .added_before = contains(state.added, files.config_dir),
        .record = record,
        .init = observed.init.state,
        .line = observed.init.line,
        .mentions_fx_rule = observed.init.mentions_fx_rule,
        .fx_lua = observed.fx_lua,
        .check_ok = observed.check_ok,
    });
    return switch (step) {
        .skip => |reason| traced(.skipped, @tagName(reason)),
        .add => addRule(a, rex, files, paths, pid, observed, state),
        .remove => removeRule(a, rex, files, observed, state),
    };
}

/// The file paths fx touches, all absolute and owned by the run's arena.
const Files = struct {
    config_dir: []const u8,
    init_path: []const u8,
    fx_lua_path: []const u8,
    state_dir: []const u8,
    lock_path: []const u8,
    state_path: []const u8,

    fn init(a: std.mem.Allocator, paths: Paths) !Files {
        return .{
            .config_dir = paths.config_dir,
            .init_path = try std.Io.Dir.path.join(a, &.{ paths.config_dir, init_name }),
            .fx_lua_path = try std.Io.Dir.path.join(a, &.{ paths.config_dir, fx_lua_name }),
            .state_dir = paths.state_dir,
            .lock_path = try std.Io.Dir.path.join(a, &.{ paths.state_dir, lock_name }),
            .state_path = try std.Io.Dir.path.join(a, &.{ paths.state_dir, state_name }),
        };
    }
};

const State = struct {
    added: []const []const u8 = &.{},
    gave_up: []const []const u8 = &.{},
    /// Config folders whose init.lua fx created, so removing the rule may delete it.
    created_init: []const []const u8 = &.{},
};

fn readState(a: std.mem.Allocator, path: []const u8) !State {
    const bytes = switch (try readPlain(a, path, max_small_file_bytes)) {
        .file => |file| file.bytes,
        else => return .{},
    };
    return parseState(a, bytes);
}

/// A state file that does not parse counts as empty.
fn parseState(a: std.mem.Allocator, bytes: []const u8) !State {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    const object = switch (root) {
        .object => |object| object,
        else => return .{},
    };
    const added = (try stringList(a, object, added_key)) orelse return .{};
    const gave_up = (try stringList(a, object, gave_up_key)) orelse return .{};
    const created_init = (try stringList(a, object, created_init_key)) orelse return .{};
    return .{ .added = added, .gave_up = gave_up, .created_init = created_init };
}

fn stringList(a: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const []const u8 {
    const value = object.get(key) orelse return &.{};
    const items = switch (value) {
        .array => |array| array.items,
        else => return null,
    };
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |item, *slot| {
        slot.* = switch (item) {
            .string => |text| text,
            else => return null,
        };
    }
    return out;
}

fn saveState(a: std.mem.Allocator, path: []const u8, state: State) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{
        .added = state.added,
        .gave_up = state.gave_up,
        .created_init = state.created_init,
    }, .{}, &out.writer);
    try writeReplacingPrivate(a, path, out.written());
}

fn saveStateLogged(a: std.mem.Allocator, path: []const u8, state: State) void {
    saveState(a, path, state) catch |err| traceStep("save state.json", err);
}

fn contains(list: []const []const u8, entry: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, entry)) return true;
    }
    return false;
}

fn withEntry(a: std.mem.Allocator, list: []const []const u8, entry: []const u8) ![]const []const u8 {
    if (contains(list, entry)) return list;
    const next = try a.alloc([]const u8, list.len + 1);
    @memcpy(next[0..list.len], list);
    next[list.len] = entry;
    return next;
}

fn withoutEntry(a: std.mem.Allocator, list: []const []const u8, entry: []const u8) ![]const []const u8 {
    var next: std.ArrayList([]const u8) = .empty;
    for (list) |item| {
        if (!std.mem.eql(u8, item, entry)) try next.append(a, item);
    }
    return next.toOwnedSlice(a);
}

/// Waits for Rex's record to satisfy `stop`, up to `record_wait_attempts` reads.
/// Returns the last state read, or null when a pause was cancelled.
fn waitForRecord(
    a: std.mem.Allocator,
    rex: Rex,
    pid: u32,
    stop: *const fn (plan.RecordState) bool,
) !?plan.RecordState {
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        const state = try readRecord(a, rex, pid);
        if (stop(state) or attempt == record_wait_attempts) return state;
        if (!rex.pause(rex.ctx, record_wait_ms)) return null;
    }
}

fn readRecord(a: std.mem.Allocator, rex: Rex, pid: u32) !plan.RecordState {
    const buf = try a.alloc(u8, records.max_answer_bytes);
    const answer = rex.records(rex.ctx, buf) orelse return .none;
    return records.ownRecord(a, answer, pid);
}

fn isDecided(state: plan.RecordState) bool {
    return state != .none;
}

fn isTrusted(state: plan.RecordState) bool {
    return state == .trusted;
}

const InitView = struct {
    state: plan.InitState,
    /// init.lua's bytes when it is plain; null otherwise.
    bytes: ?[]const u8 = null,
    line: plan.LineState = .absent,
    mentions_fx_rule: bool = false,
};

const Observed = struct {
    init: InitView,
    fx_lua: plan.FxLuaState,
    check_ok: bool,
};

fn observe(a: std.mem.Allocator, rex: Rex, files: Files) !Observed {
    const init = try observeInit(a, files);
    return .{
        .init = init,
        .fx_lua = try observeFxLua(a, files.fx_lua_path),
        .check_ok = init.state != .plain or rex.check(rex.ctx, files.init_path),
    };
}

fn observeInit(a: std.mem.Allocator, files: Files) !InitView {
    switch (folderState(files.config_dir)) {
        .missing => return .{ .state = .missing },
        .not_folder => return .{ .state = .not_plain },
        .folder => {},
    }
    return switch (try readPlain(a, files.init_path, plan.max_init_bytes)) {
        .missing => .{ .state = .missing },
        .not_plain => .{ .state = .not_plain },
        .too_big => .{ .state = .too_big },
        .file => |file| plainInit(files.config_dir, file.permissions, file.bytes),
    };
}

fn plainInit(config_dir: []const u8, permissions: std.Io.File.Permissions, bytes: []const u8) InitView {
    if ((permissions.toMode() & owner_write_mode) == 0 or !writable(config_dir)) {
        return .{ .state = .read_only };
    }
    if (!plan.isText(bytes)) return .{ .state = .not_text };
    return .{
        .state = .plain,
        .bytes = bytes,
        .line = plan.scanLine(bytes),
        .mentions_fx_rule = plan.mentionsFxRule(bytes),
    };
}

fn observeFxLua(a: std.mem.Allocator, path: []const u8) !plan.FxLuaState {
    return switch (try readPlain(a, path, max_small_file_bytes)) {
        .missing => .missing,
        .not_plain => .not_plain,
        .too_big => .foreign,
        .file => |file| if (plan.isOurFxLua(file.bytes)) .ours else .foreign,
    };
}

const Folder = enum { missing, folder, not_folder };

/// Looks at the path itself: a symlink to a folder is `.not_folder`.
fn folderState(path: []const u8) Folder {
    const io = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        return switch (err) {
            error.FileNotFound => .missing,
            else => .not_folder,
        };
    };
    return if (stat.kind == .directory) .folder else .not_folder;
}

fn writable(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{ .write = true }) catch return false;
    return true;
}

const Plain = union(enum) {
    missing,
    not_plain,
    too_big,
    file: PlainFile,
};

const PlainFile = struct {
    permissions: std.Io.File.Permissions,
    bytes: []u8,
};

/// Reads a regular file without following a symlink. Anything else, including a
/// read that fails, is `.not_plain`. Only an allocation failure is an error.
fn readPlain(a: std.mem.Allocator, path: []const u8, max_bytes: usize) !Plain {
    const io = io_mod.getIo();
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .no_follow) catch |err| {
        return switch (err) {
            error.FileNotFound => .missing,
            else => .not_plain,
        };
    };
    defer file.close(io);
    const stat = file.stat(io) catch return .not_plain;
    if (stat.size > max_bytes) return .too_big;
    const bytes = io_mod.readFileToEnd(a, &file, max_bytes + 1) catch |err| {
        return switch (err) {
            error.StreamTooLong => .too_big,
            error.OutOfMemory => err,
            else => .not_plain,
        };
    };
    return .{ .file = .{ .permissions = stat.permissions, .bytes = bytes } };
}

/// Re-reads init.lua and compares it with what the run observed. `original` is
/// null when the file was missing.
fn initUnchanged(a: std.mem.Allocator, path: []const u8, original: ?[]const u8) !bool {
    return switch (try readPlain(a, path, plan.max_init_bytes)) {
        .missing => original == null,
        .file => |file| if (original) |bytes| std.mem.eql(u8, file.bytes, bytes) else false,
        .not_plain, .too_big => false,
    };
}

/// What the add path changed, so a rollback knows what to undo.
const Edit = struct {
    alloc: std.mem.Allocator,
    rex: Rex,
    files: Files,
    /// init.lua's bytes before fx touched it; null when the file was missing.
    original: ?[]const u8,
    fx_lua_created: bool = false,
    init_written: bool = false,
};

fn addRule(
    a: std.mem.Allocator,
    rex: Rex,
    files: Files,
    paths: Paths,
    pid: u32,
    observed: Observed,
    state: State,
) Outcome {
    var edit: Edit = .{ .alloc = a, .rex = rex, .files = files, .original = observed.init.bytes };
    return addRuleEdits(&edit, paths, pid, observed, state) catch |err| {
        if (!edit.fx_lua_created and !edit.init_written) return traced(.skipped, @errorName(err));
        rollback(&edit);
        return traced(.rolled_back, @errorName(err));
    };
}

fn addRuleEdits(edit: *Edit, paths: Paths, pid: u32, observed: Observed, state: State) !Outcome {
    const a = edit.alloc;
    const files = edit.files;
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), files.config_dir);
    // The person may have made their own fx.lua since fx looked, so look again before
    // writing: fx never writes over a file it does not own.
    if (try observeFxLua(a, files.fx_lua_path) != observed.fx_lua) {
        return traced(.skipped, "fx.lua changed while fx worked");
    }
    edit.fx_lua_created = observed.fx_lua == .missing;
    try writeFxLua(a, files, paths);
    if (edit.original) |bytes| try writeBackup(a, files.state_dir, bytes);

    const unchanged = try initUnchanged(a, files.init_path, edit.original);
    if (!unchanged) {
        if (edit.fx_lua_created) {
            deleteIfPresent(files.fx_lua_path) catch |err| traceStep("undo fx.lua", err);
        }
        return traced(.skipped, "init.lua changed while fx worked");
    }

    const next = try withRuleLine(a, edit.original);
    if (!std.mem.eql(u8, next, edit.original orelse "")) {
        try io_mod.writeFileAtomic(a, files.init_path, next);
        edit.init_written = true;
    }

    if (!edit.rex.check(edit.rex.ctx, files.init_path)) {
        rollback(edit);
        return traced(.rolled_back, "rex config check failed after the edit");
    }
    if (!edit.rex.reload(edit.rex.ctx)) {
        rollback(edit);
        return traced(.rolled_back, "rex config reload failed");
    }

    const verdict = (try waitForRecord(a, edit.rex, pid, isTrusted)) orelse {
        rollback(edit);
        return traced(.rolled_back, "cancelled while Rex verified the rule");
    };
    var next_state = state;
    switch (verdict) {
        .trusted => {
            next_state.added = try withEntry(a, state.added, files.config_dir);
            if (edit.original == null and edit.init_written) {
                next_state.created_init = try withEntry(a, state.created_init, files.config_dir);
            }
            saveStateLogged(a, files.state_path, next_state);
            if (edit.init_written) return traced(.added, "rule added");
            return traced(.verified, "rule already in place");
        },
        .none => {
            rollback(edit);
            return traced(.rolled_back, "Rex gave no answer for fx after reload");
        },
        .no_rule, .other => {
            rollback(edit);
            next_state.gave_up = try withEntry(a, state.gave_up, files.config_dir);
            saveStateLogged(a, files.state_path, next_state);
            return traced(.rolled_back, "record not trusted after reload");
        },
    }
}

/// Undoes the add path's changes. Each step is best effort: the run has already failed.
/// init.lua is not restored from the backup, because the person may have edited it
/// during the attempt. Only fx's line is taken out of the text that is there now.
fn rollback(edit: *Edit) void {
    if (edit.init_written) {
        const fx_created_init = edit.original == null;
        removeOwnLine(edit.alloc, edit.files.init_path, fx_created_init) catch |err| traceStep("remove our line", err);
    }
    if (edit.fx_lua_created) {
        deleteIfPresent(edit.files.fx_lua_path) catch |err| traceStep("delete fx.lua", err);
    }
    _ = reloadRex(edit.rex, "rollback");
}

/// Takes fx's line out of init.lua as it is now. Leaves the file alone when the
/// line is gone or the file is no longer plain text. An emptied file is deleted
/// only when fx created it; the person's own empty file stays.
fn removeOwnLine(a: std.mem.Allocator, init_path: []const u8, fx_created_init: bool) !void {
    const bytes = switch (try readPlain(a, init_path, plan.max_init_bytes)) {
        .file => |file| file.bytes,
        else => {
            debug_trace.logf(trace_scope, "rollback left init.lua alone: it is no longer plain text", .{});
            return;
        },
    };
    if (plan.scanLine(bytes) != .ours) {
        debug_trace.logf(trace_scope, "rollback left init.lua alone: fx's line is not there", .{});
        return;
    }
    const buf = try a.alloc(u8, bytes.len);
    const next = plan.removeLine(bytes, buf);
    if (next.len == 0 and fx_created_init) return deleteIfPresent(init_path);
    try io_mod.writeFileAtomic(a, init_path, next);
}

fn removeRule(a: std.mem.Allocator, rex: Rex, files: Files, observed: Observed, state: State) Outcome {
    const original = observed.init.bytes orelse return traced(.skipped, "init.lua is not plain");
    return removeRuleEdits(a, rex, files, original, observed.fx_lua, state) catch |err| {
        return traced(.skipped, @errorName(err));
    };
}

/// An error before the write leaves init.lua as it was. After the write, fx's line
/// stays removed, so nothing is put back.
fn removeRuleEdits(
    a: std.mem.Allocator,
    rex: Rex,
    files: Files,
    original: []const u8,
    fx_lua: plan.FxLuaState,
    state: State,
) !Outcome {
    try writeBackup(a, files.state_dir, original);
    const unchanged = try initUnchanged(a, files.init_path, original);
    if (!unchanged) return traced(.skipped, "init.lua changed while fx worked");

    const buf = try a.alloc(u8, original.len);
    const removed = plan.removeLine(original, buf);
    if (removed.len == 0 and contains(state.created_init, files.config_dir)) {
        // fx created the file and our line was all of it, so the file goes back to
        // missing. There is no file left to check.
        try deleteIfPresent(files.init_path);
    } else {
        try io_mod.writeFileAtomic(a, files.init_path, removed);
        if (!rex.check(rex.ctx, files.init_path)) {
            debug_trace.logf(trace_scope, "rex config check failed after the removal, fx's line stays removed", .{});
        }
    }

    // Look at fx.lua again: the person may have replaced it with their own since fx looked.
    const fx_lua_still_ours = (observeFxLua(a, files.fx_lua_path) catch .foreign) == .ours;
    if (fx_lua == .ours and fx_lua_still_ours) {
        deleteIfPresent(files.fx_lua_path) catch |err| traceStep("delete fx.lua", err);
    }
    _ = reloadRex(rex, "after the removal");
    var next_state = state;
    next_state.added = try withoutEntry(a, state.added, files.config_dir);
    next_state.created_init = try withoutEntry(a, state.created_init, files.config_dir);
    saveStateLogged(a, files.state_path, next_state);
    return traced(.removed, "rule removed");
}

/// The rule's text for init.lua: the require line on a new file, else our line added.
fn withRuleLine(a: std.mem.Allocator, original: ?[]const u8) ![]const u8 {
    const text = original orelse return plan.require_line ++ "\n";
    const buf = try a.alloc(u8, plan.addedLen(text));
    return plan.addLine(text, buf);
}

fn writeFxLua(a: std.mem.Allocator, files: Files, paths: Paths) !void {
    const buf = try a.alloc(u8, max_small_file_bytes);
    const text = plan.fxLua(buf, paths.exe_path, paths.sessions_dir) orelse return error.FxLuaTooLarge;
    try io_mod.writeFileAtomic(a, files.fx_lua_path, text);
}

/// Copies init.lua's bytes to a new, private file. An existing backup is an
/// error, so a run never overwrites one.
fn writeBackup(a: std.mem.Allocator, state_dir: []const u8, bytes: []const u8) !void {
    const io = io_mod.getIo();
    const name = try a.print("{s}{d}", .{ backup_name_prefix, io_mod.milliTimestamp() });
    const path = try std.Io.Dir.path.join(a, &.{ state_dir, name });
    (try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = private_file_mode })).close(io);
    try io_mod.writeFileAtomic(a, path, bytes);
}

/// Replaces a file that fx owns and keeps private: it is created private first,
/// so the atomic rename keeps mode 0o600.
fn writeReplacingPrivate(a: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const io = io_mod.getIo();
    (try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = private_file_mode })).close(io);
    try io_mod.writeFileAtomic(a, path, bytes);
}

fn deleteIfPresent(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn reloadRex(rex: Rex, why: []const u8) bool {
    const ok = rex.reload(rex.ctx);
    if (!ok) debug_trace.logf(trace_scope, "rex config reload failed why={s}", .{why});
    return ok;
}

fn traceStep(step: []const u8, err: anyerror) void {
    debug_trace.logf(trace_scope, "step failed step={s} error={s}", .{ step, @errorName(err) });
}

/// Traces the outcome and its reason. Never pass file contents or Rex's answer as a reason.
fn traced(outcome: Outcome, reason: []const u8) Outcome {
    debug_trace.logf(trace_scope, "outcome={s} reason={s}", .{ @tagName(outcome), reason });
    return outcome;
}

const testing = std.testing;
const test_pid: u32 = 4242;
const original_text = "-- mine\n";
const user_line = "-- added by the user\n";
const foreign_fx_lua_text = "-- the person's own fx.lua\n";
const max_test_bytes: usize = 64 * 1024;

const FakeRex = struct {
    pid: u32,
    /// Rex's answer about fx's record before and after a successful reload.
    before: plan.RecordState,
    after: plan.RecordState,
    check_mode: CheckMode = .always_ok,
    /// A user edit the next check makes to init.lua once it has read fx's line.
    user_edit: UserEdit = .none,
    /// A path where the next check writes the person's own fx.lua, once.
    foreign_fx_lua_at: ?[]const u8 = null,
    null_answers: NullAnswers = .never,
    reload_ok: bool = true,
    reloaded: bool = false,
    check_calls: usize = 0,
    reload_calls: usize = 0,
    pause_calls: usize = 0,

    const CheckMode = enum { always_ok, always_fail, fail_on_broken_text, fail_on_our_line };
    const UserEdit = enum { none, append_line, remove_our_line };
    /// When Rex gives no answer: never, always, or only after a successful reload.
    const NullAnswers = enum { never, always, after_reload };

    fn rex(self: *FakeRex) Rex {
        return .{
            .ctx = self,
            .records = recordsFn,
            .check = checkFn,
            .reload = reloadFn,
            .pause = pauseFn,
        };
    }

    fn from(ctx: *anyopaque) *FakeRex {
        return @ptrCast(@alignCast(ctx));
    }

    fn recordsFn(ctx: *anyopaque, out: []u8) ?[]const u8 {
        const self = from(ctx);
        const silent = switch (self.null_answers) {
            .never => false,
            .always => true,
            .after_reload => self.reloaded,
        };
        if (silent) return null;
        return answerJson(out, if (self.reloaded) self.after else self.before, self.pid);
    }

    fn checkFn(ctx: *anyopaque, init_path: []const u8) bool {
        const self = from(ctx);
        self.check_calls += 1;
        var buf: [16 * 1024]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io_mod.getIo(), init_path, &buf) catch return false;
        const verdict = switch (self.check_mode) {
            .always_ok => true,
            .always_fail => false,
            .fail_on_broken_text => std.mem.find(u8, text, "BROKEN") == null,
            .fail_on_our_line => std.mem.find(u8, text, plan.require_line) == null,
        };
        self.editDuringCheck(init_path, text);
        if (self.foreign_fx_lua_at) |path| {
            writeTestFile(path, foreign_fx_lua_text) catch @panic("foreign fx.lua failed to write");
            self.foreign_fx_lua_at = null;
        }
        return verdict;
    }

    /// Plays the user edit once, after the check has read fx's line, so the verdict
    /// is about fx's text and the file changes while the check runs.
    fn editDuringCheck(self: *FakeRex, init_path: []const u8, text: []const u8) void {
        if (self.user_edit == .none or std.mem.find(u8, text, plan.require_line) == null) return;
        var out: [16 * 1024]u8 = undefined;
        const edited: []const u8 = switch (self.user_edit) {
            .none => return,
            .append_line => std.mem.print(&out, "{s}{s}", .{ text, user_line }) catch @panic("user edit does not fit"),
            .remove_our_line => plan.removeLine(text, &out),
        };
        writeTestFile(init_path, edited) catch @panic("user edit failed to write");
        self.user_edit = .none;
    }

    fn reloadFn(ctx: *anyopaque) bool {
        const self = from(ctx);
        self.reload_calls += 1;
        if (!self.reload_ok) return false;
        self.reloaded = true;
        return true;
    }

    fn pauseFn(ctx: *anyopaque, _: u64) bool {
        from(ctx).pause_calls += 1;
        return true;
    }
};

fn answerJson(out: []u8, state: plan.RecordState, pid: u32) ?[]const u8 {
    const body = switch (state) {
        .none => return std.mem.print(out, "{{\"records\":[]}}", .{}) catch null,
        .trusted => "\"trusted\":true",
        .no_rule => "\"trusted\":false,\"untrusted_reason\":\"no_rule\"",
        .other => "\"trusted\":false,\"untrusted_reason\":\"command_changed\"",
    };
    return std.mem.print(out, "{{\"records\":[{{\"owner\":{{\"pid\":{d}}},{s}}}]}}", .{ pid, body }) catch null;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    paths: Paths,

    fn create() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const root = try io_mod.dirRealpathAlloc(a, tmp.dir, ".");
        return .{
            .tmp = tmp,
            .arena = arena,
            .paths = .{
                .config_dir = try a.print("{s}/rex", .{root}),
                .state_dir = try a.print("{s}/fx/rex", .{root}),
                .sessions_dir = try a.print("{s}/fx/sessions/v2", .{root}),
                .exe_path = "/Users/example/.local/bin/fx",
            },
        };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn alloc(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn pathIn(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.Io.Dir.path.join(a, &.{ dir, name });
}

fn makeDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), path);
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io_mod.getIo(), .{ .sub_path = path, .data = bytes });
}

fn readTestFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, a, .limited(max_test_bytes));
}

fn expectFile(a: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const bytes = try readTestFile(a, path);
    try testing.expectEqualStrings(expected, bytes);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn stateLists(a: std.mem.Allocator, state_path: []const u8, key: []const u8, entry: []const u8) !bool {
    const bytes = try readTestFile(a, state_path);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const items = root.object.get(key).?.array.items;
    for (items) |item| {
        if (std.mem.eql(u8, item.string, entry)) return true;
    }
    return false;
}

test "rex apply: fresh config adds the rule and verifies it" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, plan.require_line ++ "\n");
    var buf: [1024]u8 = undefined;
    try expectFile(a, fx_lua, plan.fxLua(&buf, p.exe_path, p.sessions_dir).?);
    try testing.expect(try stateLists(a, state, added_key, p.config_dir));
    try testing.expectEqual(@as(usize, 1), rex_state.reload_calls);
}

test "rex apply: existing init.lua gets our line at the end" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const old = "rex.set(\"resume.trust.claude.dir\", \"~/code\")\nrex.bind(\"cmd+d\", \"pane.split\")\n";
    try makeDir(p.config_dir);
    try writeTestFile(init, old);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, old ++ plan.require_line ++ "\n");
}

test "rex apply: a broken config is left alone" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const broken = "rex.set(\"BROKEN\", {})\n";
    try makeDir(p.config_dir);
    try writeTestFile(init, broken);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .check_mode = .fail_on_broken_text };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, broken);
    try testing.expect(!fileExists(fx_lua));
    try testing.expectEqual(@as(usize, 0), rex_state.reload_calls);
}

test "rex apply: a failed check after the write rolls back" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .check_mode = .fail_on_our_line };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a failed reload rolls back" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .reload_ok = false };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expectEqual(@as(usize, 2), rex_state.reload_calls);
}

test "rex apply: a user line added during the attempt survives the rollback" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{
        .pid = test_pid,
        .before = .no_rule,
        .after = .trusted,
        .check_mode = .fail_on_our_line,
        .user_edit = .append_line,
    };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text ++ user_line);
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a rule line the user removed during the attempt is not added back" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{
        .pid = test_pid,
        .before = .no_rule,
        .after = .trusted,
        .check_mode = .fail_on_our_line,
        .user_edit = .remove_our_line,
    };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!fileExists(state));
}

test "rex apply: a record that stays no_rule rolls back and gives up" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .no_rule };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(try stateLists(a, state, gave_up_key, p.config_dir));
    try testing.expectEqual(@as(usize, 2), rex_state.reload_calls);

    const state_before = try readTestFile(a, state);
    const reloads_before = rex_state.reload_calls;
    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try expectFile(a, state, state_before);
    try testing.expectEqual(reloads_before, rex_state.reload_calls);
}

test "rex apply: no answer after reload rolls back without giving up" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .null_answers = .after_reload };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!fileExists(state));

    rex_state.reloaded = false;
    rex_state.null_answers = .never;
    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text ++ plan.require_line ++ "\n");
    try testing.expect(try stateLists(a, state, added_key, p.config_dir));
    try testing.expect(!try stateLists(a, state, gave_up_key, p.config_dir));
}

test "rex apply: turning the setting off does not wait for Rex's record" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    rex_state.null_answers = .always;
    rex_state.pause_calls = 0;
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    try testing.expectEqual(@as(usize, 0), rex_state.pause_calls);
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a read-only init.lua is skipped" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), init, .{ .permissions = std.Io.File.Permissions.fromMode(0o444) });
    try file.writeStreamingAll(io_mod.getIo(), original_text);
    file.close(io_mod.getIo());
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a symlinked init.lua is skipped and its target stays" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const target = try pathIn(a, p.config_dir, "target.lua");
    try makeDir(p.config_dir);
    try writeTestFile(target, original_text);
    try std.Io.Dir.cwd().symLink(io_mod.getIo(), target, init, .{});
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, target, original_text);
    try testing.expectEqual(@as(usize, 0), rex_state.reload_calls);
}

test "rex apply: a foreign fx.lua is skipped" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const foreign = "-- someone else's file\n";
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    try writeTestFile(fx_lua, foreign);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, fx_lua, foreign);
    try expectFile(a, init, original_text);
    try testing.expectEqual(@as(usize, 0), rex_state.reload_calls);
}

test "rex apply: an fx.lua the person writes while fx works is not written over" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    // observe sees no fx.lua; the person writes one during its check.
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .foreign_fx_lua_at = fx_lua };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, fx_lua, foreign_fx_lua_text);
    try expectFile(a, init, original_text);
    try testing.expectEqual(@as(usize, 0), rex_state.reload_calls);
}

test "rex apply: the person's empty init.lua stays when the setting is turned off" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, "");
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try testing.expectEqual(plan.LineState.ours, plan.scanLine(try readTestFile(a, init)));
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    try expectFile(a, init, "");
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a rollback keeps the person's empty init.lua" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, "");
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted, .check_mode = .fail_on_our_line };

    try testing.expectEqual(Outcome.rolled_back, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, "");
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: a rule the user removed stays removed" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try makeDir(p.state_dir);
    try writeTestFile(init, original_text);
    const state_json = try a.print("{{\"added\":[\"{s}\"],\"gave_up\":[]}}", .{p.config_dir});
    try writeTestFile(state, state_json);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
}

test "rex apply: turning the setting off removes our line" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!try stateLists(a, state, added_key, p.config_dir));
}

test "rex apply: a failed check after the removal keeps fx's line removed" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    rex_state.check_mode = .always_fail;
    const reloads_before = rex_state.reload_calls;
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!try stateLists(a, state, added_key, p.config_dir));
    try testing.expectEqual(reloads_before + 1, rex_state.reload_calls);
}

test "rex apply: a fresh install removed again deletes init.lua without a check" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, plan.require_line ++ "\n");
    const checks_before = rex_state.check_calls;
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    // observe checks the file once before the removal; the deleted file is never checked.
    try testing.expectEqual(checks_before + 1, rex_state.check_calls);
    try testing.expect(!fileExists(init));
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!try stateLists(a, state, added_key, p.config_dir));
}

test "rex apply: a held lock skips the run" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const lock_path = try pathIn(a, p.state_dir, lock_name);
    try makeDir(p.config_dir);
    try makeDir(p.state_dir);
    try writeTestFile(init, original_text);
    var held = try std.Io.Dir.cwd().createFile(io_mod.getIo(), lock_path, .{ .truncate = false });
    defer held.close(io_mod.getIo());
    try testing.expect(try held.tryLock(io_mod.getIo(), .exclusive));
    defer held.unlock(io_mod.getIo());
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expectEqual(@as(usize, 0), rex_state.reload_calls);
}

test "rex apply: a trusted record skips the run" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const fx_lua = try pathIn(a, p.config_dir, fx_lua_name);
    const state = try pathIn(a, p.state_dir, state_name);
    try makeDir(p.config_dir);
    try writeTestFile(init, original_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .trusted, .after = .trusted };

    try testing.expectEqual(Outcome.skipped, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, original_text);
    try testing.expect(!fileExists(fx_lua));
    try testing.expect(!fileExists(state));
}

test "rex apply: CRLF init.lua without a final newline comes back as it was" {
    var fx = try Fixture.create();
    defer fx.deinit();
    const a = fx.alloc();
    const p = fx.paths;
    const init = try pathIn(a, p.config_dir, init_name);
    const crlf_text = "rex.set(\"a\", {})\r\nrex.bind(\"x\", \"y\")";
    try makeDir(p.config_dir);
    try writeTestFile(init, crlf_text);
    var rex_state: FakeRex = .{ .pid = test_pid, .before = .no_rule, .after = .trusted };

    try testing.expectEqual(Outcome.added, run(a, rex_state.rex(), p, test_pid, true));
    try expectFile(a, init, crlf_text ++ "\r\n" ++ plan.require_line);
    try testing.expectEqual(Outcome.removed, run(a, rex_state.rex(), p, test_pid, false));
    try expectFile(a, init, crlf_text);
}
