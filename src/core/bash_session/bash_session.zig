//! One agent's saved bash state for the one bash tool. Each bash tool program
//! is one captured bash command. Its after-startup text, `. '<dir>/env.sh'`,
//! makes the program's own shell load the state the last program saved and save
//! it again when the program ends, so a program killed by a signal saves nothing,
//! and its save record says `pending` until fx reads it
//! (`tests/tla/bash_tool/ResultStore.tla` `Finish`, `StateNeverTorn`,
//! `EndedSaves`). The state never holds the MCP token. This module imports only
//! `std`, so `zig test` runs its tests alone.
const std = @import("std");

/// The whole code a program sends to wait for the program that is running.
pub const wait_word = "wait_more";

/// The largest bash state one program saves (R3.7). A larger state is not
/// saved: the last complete state stays, and fx's result says so
/// (`tests/tla/bash_tool/ResultStore.tla` `RefusalNoticed`).
pub const max_state_bytes: usize = 1 << 20;

/// Whether `code` is the wait request: `wait_word` alone, with spaces, tabs,
/// and line ends around it.
pub fn isWaitMore(code: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, code, " \t\r\n"), wait_word);
}

const default_bash = "/bin/bash";

/// The bash to run: `login_shell` when it is an absolute path to a program
/// named `bash`, else `/bin/bash`.
pub fn bashPath(login_shell: ?[]const u8) []const u8 {
    const shell = login_shell orelse return default_bash;
    if (!std.Io.Dir.path.isAbsolute(shell)) return default_bash;
    if (!std.mem.eql(u8, std.Io.Dir.path.basename(shell), "bash")) return default_bash;
    return shell;
}

const env_header =
    "# fx bash tool: load the bash state the last program saved, and save it again\n" ++
    "# when this program ends (tests/tla/bash_tool/ResultStore.tla Finish).\n";

/// The file, next to the state, that holds the folder the last saved program
/// ended in. The state never holds a folder: fx starts each program there.
const folder_file = "folder";

/// The files, next to the state, that the program's shell loads or the script
/// writes. `heal` writes or removes them again when a program damages them.
const env_file = "env.sh";
const state_file = "state.sh";

/// The files, next to the state, where the script records the startup
/// definitions. `prepare` makes them owner-only, and the script fills them with
/// `>`, which keeps that mode.
const startup_functions_file = "startup-functions";
const startup_aliases_file = "startup-aliases";

/// The file, next to the state, that says how the last program ended for its
/// save. The script writes `pending` when the program loads, `cap <bytes>` when
/// the state was over the cap, and `failed` when the save could not keep it. A
/// save that keeps the state empties the file. `takeSaveStatus` reads and empties
/// it, so a `pending` left by a program that ended without its save shows up.
const save_status_file = "save-status";
const max_status_bytes = 64;

/// Appends `path` in single quotes. A `'` in `path` becomes `'\''`, so the path
/// stays one shell word.
fn appendQuotedWord(alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    try out.append(alloc, '\'');
    for (path) |byte| {
        if (byte == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, byte);
        }
    }
    try out.append(alloc, '\'');
}

/// Appends `name='<path>'` and a newline.
fn appendQuotedAssignment(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, path: []const u8) !void {
    try out.appendSlice(alloc, name);
    try out.append(alloc, '=');
    try appendQuotedWord(alloc, out, path);
    try out.append(alloc, '\n');
}

/// Whether `name` is a plain variable name: letters, digits, and `_`, not empty.
/// Only such a name can go into the script's case pattern unchanged.
fn isVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// The env.sh script for a session whose state file is `state_path`. The caller
/// owns the result. Its paths are single-quoted, so each stays one shell word.
/// `fx_variables` are the names fx adds to every program; the script skips them
/// when it saves, so they never reach the saved state.
fn envScript(
    alloc: std.mem.Allocator,
    state_path: []const u8,
    folder_path: []const u8,
    startup_functions_path: []const u8,
    startup_aliases_path: []const u8,
    status_path: []const u8,
    fx_variables: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, env_header);
    try appendQuotedAssignment(alloc, &out, "__fx_state", state_path);
    try appendQuotedAssignment(alloc, &out, "__fx_folder", folder_path);
    try appendQuotedAssignment(alloc, &out, "__fx_startup_functions", startup_functions_path);
    try appendQuotedAssignment(alloc, &out, "__fx_startup_aliases", startup_aliases_path);
    try appendQuotedAssignment(alloc, &out, "__fx_status", status_path);
    try out.appendSlice(alloc, std.fmt.comptimePrint("__fx_max={d}\n", .{max_state_bytes}));
    try out.appendSlice(alloc, body_before_skip);
    for (fx_variables) |name| {
        try out.append(alloc, '|');
        try out.appendSlice(alloc, name);
    }
    try out.appendSlice(alloc, body_after_skip);
    return out.toOwnedSlice(alloc);
}

/// Why the last program's state was not saved. `over_cap` holds the size of the
/// state the program tried to save, in bytes. `not_saved` means the program
/// ended before its save ran, so its record still says `pending`: a `trap -`,
/// `exec`, a signal, or a stop by fx.
const SaveStatus = union(enum) {
    over_cap: usize,
    failed,
    not_saved,
};

/// The status a save record holds, with at most one line end: `pending`, `cap
/// <bytes>`, or `failed`. An empty record is null, because nothing was reported.
/// Any other text is `.failed`, so fx reports what it cannot read.
fn parseSaveStatus(text: []const u8) ?SaveStatus {
    const line = std.mem.trimEnd(u8, text, "\n");
    if (line.len == 0) return null;
    if (std.mem.eql(u8, line, "pending")) return .not_saved;
    if (std.mem.eql(u8, line, "failed")) return .failed;
    if (!std.mem.startsWith(u8, line, "cap ")) return .failed;
    const bytes = std.fmt.parseInt(usize, line["cap ".len..], 10) catch return .failed;
    return .{ .over_cap = bytes };
}

/// Why the session keeps the start folder it keeps, or drops the one the last
/// saved program wrote. Only `kept` keeps a folder. `no_record` is a session
/// with no folder file yet, the normal case of a fresh session. `gone` is a
/// saved folder that no longer exists or is not a directory. `bad_record` is a
/// folder file that is not a regular file, is too long, holds a NUL byte, is not
/// an absolute path, or cannot be read.
const StartFolderStatus = enum { kept, no_record, gone, bad_record };

/// One agent's bash session: its private folder and the text that loads its
/// state. The folder is made by `prepare` and deleted by `deinit`.
pub const Session = struct {
    /// Makes and frees this session's paths; it lives as long as the session.
    alloc: std.mem.Allocator,
    /// The private folder, `<tmp_root>/fx-bash-<pid>-<16 hex digits>`, where
    /// `<pid>` is this process's id. Owned.
    dir: ?[]u8 = null,
    /// The after-startup text of every program: `. '<dir>/env.sh'`. Owned.
    after_startup: ?[]u8 = null,
    /// The id of this session's last program, so a new program waits its
    /// turn and wait_more finds it. Owned.
    program_id: ?[]u8 = null,
    /// The folder the next program starts in, as the last saved state left it.
    /// Null means the workspace root. Owned.
    start_folder: ?[]u8 = null,
    /// Set when a repair discarded the saved state. It stays set through a failed
    /// fresh folder, and `lossPending` reads it until a program starts with the
    /// state-lost notice in its result, so the loss is never silent.
    loss_pending: bool = false,
    /// Set when a refresh dropped the start folder. `takeFolderDropped` reads and
    /// clears it, so the next call reports the drop once.
    folder_dropped: bool = false,
    /// Old folders whose removal failed, kept for a later removal. Owned. A later
    /// `heal` retries them, and `deinit` retries them last.
    left_behind: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Session {
        return .{ .alloc = alloc };
    }

    /// Makes the folder and writes its script, once. `tmp_root` must be an
    /// absolute path, because the script names the state file by its full
    /// path. It must not hold `$`, a backquote, or a backslash. The script
    /// quotes its paths, so bash does not expand them, and such a root is still
    /// refused with `error.UnsafeTmpRoot` as a plain guard. `fx_variables` are the names fx adds to every program, which the
    /// script never saves; a name that is not a plain variable name is refused
    /// with `error.InvalidVariableName` before anything is made. Before it makes
    /// the folder, it removes the folders that dead processes left in `tmp_root`
    /// (`sweepDeadFolders`). On failure nothing is left behind and the session
    /// stays unprepared. Returns how many dead folders the sweep removed, or 0
    /// when the session was already prepared.
    pub fn prepare(self: *Session, io: std.Io, tmp_root: []const u8, fx_variables: []const []const u8) !usize {
        if (self.dir != null) return 0;
        const alloc = self.alloc;
        if (!std.Io.Dir.path.isAbsolute(tmp_root)) return error.RelativeTmpRoot;
        if (std.mem.findAny(u8, tmp_root, "$`\\") != null) return error.UnsafeTmpRoot;
        for (fx_variables) |name| {
            if (!isVariableName(name)) return error.InvalidVariableName;
        }
        const swept = sweepDeadFolders(io, tmp_root);
        var suffix: [8]u8 = undefined;
        io.random(&suffix);
        const hex = std.fmt.bytesToHex(suffix, .lower);
        const dir = try alloc.print("{s}/{s}{d}-{s}", .{ tmp_root, folder_prefix, processId(), &hex });
        errdefer alloc.free(dir);
        const env_path = try alloc.print("{s}/{s}", .{ dir, env_file });
        defer alloc.free(env_path);
        const script = try sessionEnvScript(alloc, dir, fx_variables);
        defer alloc.free(script);
        const after_startup = try startupTextFor(alloc, env_path);
        errdefer alloc.free(after_startup);

        try std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700));
        errdefer removeTree(io, dir);
        var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer folder.close(io);
        try writePrivateFile(io, folder, env_file, script);
        try writePrivateFile(io, folder, startup_functions_file, "");
        try writePrivateFile(io, folder, startup_aliases_file, "");
        try writePrivateFile(io, folder, save_status_file, "");

        self.dir = dir;
        self.after_startup = after_startup;
        return swept;
    }

    /// The text every program's shell runs after the user's startup definitions and
    /// before the program's command, or null before `prepare`. The slice is valid
    /// until `deinit`.
    pub fn afterStartupText(self: *const Session) ?[]const u8 {
        return self.after_startup;
    }

    /// Reads the save record the last program left, then empties it, and returns
    /// what it says. It returns null when the record is empty (the save kept the
    /// state) or when the folder is gone. The record is emptied, not deleted, so
    /// the file keeps the owner-only mode `prepare` gave it, and the next
    /// program's `pending` write needs no umask change. Once the record is open
    /// as a regular file it is emptied whatever the read gives, so a record that
    /// cannot be read is reported once, not on every call. A record that cannot
    /// be read, or is not a regular file, counts as `.failed`, so fx reports the
    /// drop rather than trust it. The program can put a FIFO or a link there, so
    /// the record is opened without waiting and without following a link, and it
    /// is emptied through that same open file.
    pub fn takeSaveStatus(self: *Session, io: std.Io) ?SaveStatus {
        const dir_path = self.dir orelse return null;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
        defer dir.close(io);
        var file = openRegularFile(io, dir, save_status_file, .read_write) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotRegularFile, error.SymLinkLoop => {
                // Replaced now, so the program's shell, which writes this record with `>|`, never waits on it.
                // An entry that cannot be replaced stays, and the next take reports it again.
                _ = replaceRecordEntry(io, dir, save_status_file) catch false;
                return .failed;
            },
            else => return .failed,
        };
        defer file.close(io);
        // Best effort: a record that stays is read again by the next take, so its notice repeats.
        defer file.setLength(io, 0) catch {};
        const text = readOpenedFile(self.alloc, file, max_status_bytes) catch return .failed;
        defer self.alloc.free(text);
        return parseSaveStatus(text);
    }

    /// Stores `id` as the id of this session's last program, freeing the one
    /// before it. If the copy fails, the old id stays.
    pub fn setProgram(self: *Session, id: []const u8) !void {
        const owned = try self.alloc.dupe(u8, id);
        if (self.program_id) |old| self.alloc.free(old);
        self.program_id = owned;
    }

    /// The id of this session's last program, or null before one is set.
    pub fn program(self: *const Session) ?[]const u8 {
        return self.program_id;
    }

    /// The folder the next program starts in, or null for the workspace root.
    /// The slice is valid until the next `refreshStartFolder` or `deinit`.
    pub fn startFolder(self: *const Session) ?[]const u8 {
        return self.start_folder;
    }

    /// Reads the folder the last saved program ended in, keeps it when it is an
    /// absolute path, with no NUL byte, that opens as a directory, and returns why
    /// it kept it or dropped it. The folder file must be a regular file: a FIFO,
    /// a link, or any other kind is a bad record, and the read never waits on it.
    /// Only `.kept` keeps a folder, so anything else means the workspace root.
    pub fn refreshStartFolder(self: *Session, io: std.Io) StartFolderStatus {
        const status = self.readStartFolder(io);
        switch (status) {
            .gone, .bad_record => self.folder_dropped = true,
            .kept, .no_record => {},
        }
        return status;
    }

    /// Reads the folder file and keeps the folder it names, as `refreshStartFolder`
    /// says. The session folder itself may be gone, which leaves no folder file to
    /// report, so that is `.no_record`; `heal` makes a new folder and reports it.
    fn readStartFolder(self: *Session, io: std.Io) StartFolderStatus {
        if (self.start_folder) |old| self.alloc.free(old);
        self.start_folder = null;
        const dir_path = self.dir orelse return .no_record;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return .no_record;
        defer dir.close(io);
        var file = openRegularFile(io, dir, folder_file, .read_only) catch |err| switch (err) {
            error.FileNotFound => return .no_record,
            error.NotRegularFile, error.SymLinkLoop => {
                // Unlinked, never followed. A folder file that cannot be unlinked stays, and the next refresh reports it again.
                dir.deleteFile(io, folder_file) catch {};
                return .bad_record;
            },
            else => return .bad_record,
        };
        defer file.close(io);
        const folder = readOpenedFile(self.alloc, file, std.Io.Dir.max_path_bytes) catch return .bad_record;
        if (!std.Io.Dir.path.isAbsolute(folder) or std.mem.findScalar(u8, folder, 0) != null) {
            self.alloc.free(folder);
            return .bad_record;
        }
        var target = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |err| {
            self.alloc.free(folder);
            return switch (err) {
                error.FileNotFound, error.NotDir => .gone,
                else => .bad_record,
            };
        };
        target.close(io);
        self.start_folder = folder;
        return .kept;
    }

    /// Returns whether a refresh dropped the start folder since the last call, and
    /// clears the flag. The next call reports a drop that the last program's end made.
    pub fn takeFolderDropped(self: *Session) bool {
        const dropped = self.folder_dropped;
        self.folder_dropped = false;
        return dropped;
    }

    /// Checks the session folder before a program starts and repairs what a
    /// program, or a stray entry, put in its place. Nothing here follows a link.
    /// Each repair is listed in the result, and a repair that fails keeps the ones
    /// before it. A repair that fails starts a fresh session: the old folder is
    /// removed as far as it can be, and a new one is made as `prepare` makes one,
    /// so the state it held is lost. A folder that is gone, or is not a directory,
    /// is made again the same way. `env.sh` is written again when it is missing or
    /// not a regular file. A `state.sh` that is not a regular file is removed, which
    /// loses the state. A `folder` file that is not a regular file is removed, and
    /// the start folder it named is reported as dropped. A directory at the save
    /// record is removed, and an empty record is made. A file, link, or FIFO there
    /// stays for `takeSaveStatus`, which reports it once. Each startup record that
    /// is not a regular file is replaced, a directory included. Call it after
    /// `prepare`. It does not fail: anything that could not be done is in the result.
    pub fn heal(self: *Session, io: std.Io, fx_variables: []const []const u8) Healed {
        self.retryLeftBehind(io);
        var healed: Healed = .{};
        self.repairFolder(io, fx_variables, &healed) catch |err| {
            healed.repair_failed = err;
            self.startFresh(io, fx_variables, &healed, err) catch |fresh_err| {
                healed.fresh_failed = fresh_err;
            };
        };
        return healed;
    }

    /// Removes the old folder after a repair failed with `cause`, and makes a new one.
    /// The removal never follows a link. A removal that fails is recorded, and the
    /// new folder is made anyway. With no folder to forget, the failure is `cause`.
    fn startFresh(self: *Session, io: std.Io, fx_variables: []const []const u8, healed: *Healed, cause: anyerror) !void {
        const dir_path = self.dir orelse return cause;
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| {
            healed.forget_failed = err;
            // The folder stays on disk, so it is kept for a later removal. When the list is full, the reported failure names the folder.
            self.keepLeftBehind(dir_path) catch {};
        };
        try self.makeFresh(io, fx_variables, healed);
    }

    /// Forgets the session's folder and makes a new one as `prepare` does. The state
    /// the old folder held is lost. `loss_pending` is set before the folder is
    /// forgotten, so the loss stays marked even when the new folder cannot be made.
    fn makeFresh(self: *Session, io: std.Io, fx_variables: []const []const u8, healed: *Healed) !void {
        const dir_path = self.dir orelse return error.SessionNotPrepared;
        const root = try self.alloc.dupe(u8, std.Io.Dir.path.dirname(dir_path) orelse return error.SessionNotPrepared);
        defer self.alloc.free(root);
        self.loss_pending = true;
        self.forgetFolder();
        healed.swept = try self.prepare(io, root, fx_variables);
        healed.add(.state_lost, "session");
    }

    /// Whether a repair discarded the saved state, and no program has started since
    /// with the state-lost notice in its result.
    pub fn lossPending(self: *const Session) bool {
        return self.loss_pending;
    }

    /// Clears the loss mark. The caller does this only after a program started and
    /// its result, which carries the state-lost notice, was delivered.
    pub fn clearLossPending(self: *Session) void {
        self.loss_pending = false;
    }

    /// Keeps `path`, an old folder whose removal failed, for a later removal. The
    /// list is bounded, so a full list refuses the path, and the caller reports it.
    fn keepLeftBehind(self: *Session, path: []const u8) !void {
        if (self.left_behind.items.len >= max_left_behind) return error.TooManyLeftBehind;
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        try self.left_behind.append(self.alloc, owned);
    }

    /// Retries the removal of each kept old folder, and keeps the ones that still
    /// cannot be removed. A retry that fails is tried again later.
    fn retryLeftBehind(self: *Session, io: std.Io) void {
        var index: usize = 0;
        while (index < self.left_behind.items.len) {
            if (removeAbandoned(io, self.left_behind.items[index])) |_| {
                self.alloc.free(self.left_behind.orderedRemove(index));
            } else |_| {
                // Still on disk: the folder stays in the list and the next retry tries it again.
                index += 1;
            }
        }
    }

    /// Runs the repairs in order, into `healed`. The first error stops them, and the
    /// repairs made before it stay in `healed`.
    fn repairFolder(self: *Session, io: std.Io, fx_variables: []const []const u8, healed: *Healed) !void {
        const dir_path = self.dir orelse return error.SessionNotPrepared;
        if (!try isFolder(io, dir_path)) {
            // Whatever stands at the old path, a file or a link or nothing, is removed without following a link.
            std.Io.Dir.cwd().deleteTree(io, dir_path) catch {}; // Best effort: the new folder has another name, so an entry that stays here is harmless.
            return self.makeFresh(io, fx_variables, healed);
        }
        var folder = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer folder.close(io);
        const env_stat = try entryStat(io, folder, env_file);
        if (env_stat) |stat| {
            if (stat.kind != .file) try removeEntry(io, folder, env_file, stat.kind);
        }
        if (env_stat == null or isDamaged(env_stat.?)) {
            try self.writeEnv(io, folder, dir_path, fx_variables);
            healed.add(.env_rewritten, env_file);
        }
        if (try entryStat(io, folder, state_file)) |stat| {
            if (isDamaged(stat)) {
                try removeEntry(io, folder, state_file, stat.kind);
                self.loss_pending = true;
                healed.add(.state_lost, state_file);
            }
        }
        if (try entryStat(io, folder, folder_file)) |stat| {
            if (isDamaged(stat)) {
                // The start folder the file named is dropped, and the next call reports that once.
                self.folder_dropped = true;
                if (removeEntry(io, folder, folder_file, stat.kind)) |_| healed.add(.record_replaced, folder_file) else |_| {} // A folder file that stays is refused by refresh, and reported again.
            }
        }
        if (try entryKind(io, folder, save_status_file)) |kind| {
            if (kind == .directory) {
                if (try replaceRecordEntry(io, folder, save_status_file)) healed.add(.record_replaced, save_status_file);
            }
        }
        for ([_][]const u8{ startup_functions_file, startup_aliases_file }) |name| {
            if (try replaceRecordEntry(io, folder, name)) healed.add(.record_replaced, name);
        }
    }

    /// Frees the session's folder and what `prepare` made for it, so the next
    /// `prepare` makes a new one. The folder's state is gone with it.
    fn forgetFolder(self: *Session) void {
        if (self.dir) |dir| self.alloc.free(dir);
        if (self.after_startup) |text| self.alloc.free(text);
        if (self.start_folder) |folder| self.alloc.free(folder);
        self.dir = null;
        self.after_startup = null;
        self.start_folder = null;
        self.folder_dropped = false;
    }

    /// Writes the session's env.sh again, as `prepare` writes it.
    fn writeEnv(self: *Session, io: std.Io, folder: std.Io.Dir, dir: []const u8, fx_variables: []const []const u8) !void {
        const script = try sessionEnvScript(self.alloc, dir, fx_variables);
        defer self.alloc.free(script);
        try writePrivateFile(io, folder, env_file, script);
    }

    /// Deletes the session folder and frees what the session holds, after one more
    /// retry for each old folder a failed removal left behind. Returns how many of
    /// those are still on disk, so the caller can log them. The session is then
    /// unprepared, so `prepare` can make a new folder. The count is a result, not
    /// a flag: a caller that drops it does not compile, so every end of a session
    /// goes through `tool_dispatch.closeBashSession`, which logs it.
    pub fn deinit(self: *Session, io: std.Io) usize {
        const alloc = self.alloc;
        if (self.dir) |dir| {
            removeTree(io, dir);
            alloc.free(dir);
        }
        self.retryLeftBehind(io);
        const left = self.left_behind.items.len;
        for (self.left_behind.items) |path| alloc.free(path);
        self.left_behind.deinit(alloc);
        if (self.after_startup) |text| alloc.free(text);
        if (self.program_id) |id| alloc.free(id);
        if (self.start_folder) |folder| alloc.free(folder);
        self.* = .{ .alloc = alloc };
        return left;
    }
};

/// How many old folders a session keeps for a later removal. A fresh folder is made
/// only after a repair fails, so this bound is far above what happens.
const max_left_behind = 8;

/// The prefix of every bash session folder's name, which the sweep looks for.
const folder_prefix = "fx-bash-";

/// This process's id, which names its bash session folders.
fn processId() std.posix.pid_t {
    return std.posix.system.getpid();
}

/// The process id in a session folder's name, `fx-bash-<pid>-<anything>`, or
/// null for any other name, or for a pid that is not a positive number.
fn folderOwner(name: []const u8) ?std.posix.pid_t {
    if (!std.mem.startsWith(u8, name, folder_prefix)) return null;
    const rest = name[folder_prefix.len..];
    const end = std.mem.findScalar(u8, rest, '-') orelse return null;
    const digits = rest[0..end];
    if (digits.len == 0) return null;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const pid = std.fmt.parseInt(std.posix.pid_t, digits, 10) catch return null;
    return if (pid > 0) pid else null;
}

/// Whether `pid` names no process. Only "no such process" counts as gone. A
/// permission error or any other result may be a live process, so it is alive.
fn processGone(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// Deletes the folders in `tmp_root` that dead processes left, and returns how
/// many it deleted. A process killed by a signal cannot run `deinit`, so the
/// folder it made stays until a later session in the same temp folder clears
/// it. Only a real directory named `fx-bash-<pid>-...`, whose pid names no
/// process, is removed. A link or a file is never followed or removed, and this
/// process's own folders and those of a live process stay. Best effort: whatever
/// cannot be opened or deleted stays, and a later session tries again.
fn sweepDeadFolders(io: std.Io, tmp_root: []const u8) usize {
    var removed: usize = 0;
    var root = std.Io.Dir.cwd().openDir(io, tmp_root, .{ .iterate = true }) catch return removed; // Best effort: a later session sweeps again.
    defer root.close(io);
    const own = processId();
    var entries = root.iterate();
    while (true) {
        const entry = (entries.next(io) catch return removed) orelse break; // Best effort: stop here, a later session sweeps again.
        if (entry.kind != .directory) continue;
        const pid = folderOwner(entry.name) orelse continue;
        if (pid == own or !processGone(pid)) continue;
        root.deleteTree(io, entry.name) catch continue; // Best effort: this folder stays until a later session deletes it.
        removed += 1;
    }
    return removed;
}

/// Writes `bytes` as the owner-only entry `name` of the session folder. Every write
/// fx makes there goes through this. The bytes go to a new temporary entry with a
/// random name, created exclusively and without following a link, and the entry is
/// then renamed over `name` (R3.4). A rename replaces an entry and never follows
/// it, so a link, FIFO, or directory at `name` is replaced, never written through.
fn writePrivateFile(io: std.Io, folder: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    var temp_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const temp = try std.mem.print(&temp_buffer, ".{s}-{s}.tmp", .{ name, &hex });
    try writeViaTemp(io, folder, name, bytes, temp);
}

/// Creates the temporary entry `temp` in `folder` exclusively and without following
/// a link, writes `bytes` to it, and renames it over `name`. The temporary entry is
/// removed on any error, so none is left behind.
fn writeViaTemp(io: std.Io, folder: std.Io.Dir, name: []const u8, bytes: []const u8, temp: []const u8) !void {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = try std.posix.openat(folder.handle, temp, flags, 0o600);
    var file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer folder.deleteFile(io, temp) catch {}; // Best effort: the entry is ours, under a random name, and nothing reads it.
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try folder.rename(temp, folder, name, io);
}

/// The after-startup text for the script at `env_path`: `. '<env_path>'`. The
/// caller owns the result.
fn startupTextFor(alloc: std.mem.Allocator, env_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\\builtin . ");
    try appendQuotedWord(alloc, &out, env_path);
    return out.toOwnedSlice(alloc);
}

/// Replaces the entry `name` of the session folder with an empty owner-only regular
/// file, as `prepare` makes it, when the entry is not a regular file. The entry is
/// removed without following a link, so a link is removed and its target is not
/// touched, and a directory is removed with its contents. A missing entry and a
/// regular file are left alone. Returns false, and leaves the entry, when it cannot
/// be removed.
fn replaceRecordEntry(io: std.Io, folder: std.Io.Dir, name: []const u8) !bool {
    const stat = (try entryStat(io, folder, name)) orelse return false;
    if (!isDamaged(stat)) return false;
    removeEntry(io, folder, name, stat.kind) catch return false;
    try writePrivateFile(io, folder, name, "");
    return true;
}

/// The kinds of repair `heal` makes.
const RepairKind = enum { state_lost, env_rewritten, record_replaced };

/// One repair `heal` made. `name` is a constant file name, or `session` for the
/// folder. It is never a path.
const Repair = struct {
    what: RepairKind,
    name: []const u8,
};

/// What one `heal` did: the repairs it made, in order, the dead folders its sweep
/// removed when it made a new folder, and each failure. The failures are kept
/// apart, so the caller can log each one.
const Healed = struct {
    repairs: [max_repairs]Repair = undefined,
    len: usize = 0,
    swept: usize = 0,
    /// The repair that failed, which started a fresh session. Null when every repair worked.
    repair_failed: ?anyerror = null,
    /// Removing the old folder failed, and the new folder was made anyway.
    forget_failed: ?anyerror = null,
    /// The new folder could not be made either, so the session has no folder and the program cannot run.
    fresh_failed: ?anyerror = null,

    /// One repair for each of the six checks, and one for a fresh session, so eight
    /// is room enough.
    const max_repairs = 8;

    fn add(self: *Healed, what: RepairKind, name: []const u8) void {
        std.debug.assert(self.len < max_repairs);
        self.repairs[self.len] = .{ .what = what, .name = name };
        self.len += 1;
    }

    /// The repairs, in the order they were made.
    pub fn items(self: *const Healed) []const Repair {
        return self.repairs[0..self.len];
    }

    /// Whether a repair lost the saved state.
    pub fn stateLost(self: *const Healed) bool {
        for (self.items()) |repair| {
            if (repair.what == .state_lost) return true;
        }
        return false;
    }
};

/// The env.sh text for the session folder `dir`: the paths of its files, and the
/// names fx adds to every program. `prepare` and `heal` write it.
fn sessionEnvScript(alloc: std.mem.Allocator, dir: []const u8, fx_variables: []const []const u8) ![]u8 {
    const state_path = try alloc.print("{s}/{s}", .{ dir, state_file });
    defer alloc.free(state_path);
    const folder_path = try alloc.print("{s}/{s}", .{ dir, folder_file });
    defer alloc.free(folder_path);
    const startup_functions_path = try alloc.print("{s}/{s}", .{ dir, startup_functions_file });
    defer alloc.free(startup_functions_path);
    const startup_aliases_path = try alloc.print("{s}/{s}", .{ dir, startup_aliases_file });
    defer alloc.free(startup_aliases_path);
    const status_path = try alloc.print("{s}/{s}", .{ dir, save_status_file });
    defer alloc.free(status_path);
    return envScript(alloc, state_path, folder_path, startup_functions_path, startup_aliases_path, status_path, fx_variables);
}

/// The kind of the entry `name` in `folder`, without following a link, or null
/// when there is no entry.
fn entryKind(io: std.Io, folder: std.Io.Dir, name: []const u8) !?std.Io.File.Kind {
    const stat = (try entryStat(io, folder, name)) orelse return null;
    return stat.kind;
}

/// The stat of the entry `name` in `folder`, without following a link, or null when
/// there is no entry. The link count is in it, so a hard link is seen.
fn entryStat(io: std.Io, folder: std.Io.Dir, name: []const u8) !?std.Io.File.Stat {
    return folder.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Whether a fixed name of the session folder is damaged: not a regular file, or a
/// regular file that another name also links to. A write through the other name
/// would reach a file outside the folder, so a damaged name is replaced and never
/// written.
fn isDamaged(stat: std.Io.File.Stat) bool {
    return stat.kind != .file or stat.nlink > 1;
}

/// Removes an old session folder whose earlier removal failed. The path is opened
/// without following a link, and only as a directory, so a link that took its place
/// is removed, never followed. The mode is restored on that open folder, so its
/// entries can be removed, and then the tree is deleted by path.
fn removeAbandoned(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const kind = (try entryKind(io, cwd, path)) orelse return;
    if (kind != .directory) return removeEntry(io, cwd, path, kind);
    // Opened without following a link, so a link that took the path is refused, never followed.
    var folder = try cwd.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer folder.close(io);
    try folder.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
    try cwd.deleteTree(io, path);
}

/// Whether `path` names a directory, without following a link.
fn isFolder(io: std.Io, path: []const u8) !bool {
    const kind = (try entryKind(io, std.Io.Dir.cwd(), path)) orelse return false;
    return kind == .directory;
}

/// Removes the entry `name` of the given kind, a directory with its contents. A
/// link is removed, not followed.
fn removeEntry(io: std.Io, folder: std.Io.Dir, name: []const u8, kind: std.Io.File.Kind) !void {
    if (kind == .directory) return folder.deleteTree(io, name);
    return folder.deleteFile(io, name);
}

/// Deletes `dir` and everything in it. A failed delete is ignored because the
/// caller is already failing or ending, and nothing here can report it.
fn removeTree(io: std.Io, dir: []const u8) void {
    // Safe to ignore: the folder is 0o700 and no program reads it after the session ends.
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// What `openRegularFile` opens a file for: reading only, or reading to truncate it.
const Access = enum { read_only, read_write };

/// Opens `name` in `dir` as a regular file, for the reads and the one truncate
/// that the session makes of files the program can also write. The open does not
/// follow a link and does not wait: a program can put a FIFO or a device at
/// either name, and a plain open of a FIFO waits for a writer. The file is
/// checked once it is open, so anything but a regular file is an error. A file that
/// another name also links to is not regular here, because a read or the truncate
/// would reach the other name's file. The caller closes the returned file.
fn openRegularFile(io: std.Io, dir: std.Io.Dir, name: []const u8, access: Access) !std.Io.File {
    const flags: std.posix.O = .{
        .ACCMODE = switch (access) {
            .read_only => .RDONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = true,
        .NONBLOCK = true,
    };
    const fd = try std.posix.openat(dir.handle, name, flags, 0);
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink > 1) return error.NotRegularFile;
    return file;
}

/// Reads at most `limit` bytes of an open regular file, from its start. A file
/// that holds more is an error. The caller frees the result. O_NONBLOCK does not
/// make a regular file's read return early, so the read cannot wait.
fn readOpenedFile(alloc: std.mem.Allocator, file: std.Io.File, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [256]u8 = undefined;
    while (true) {
        const n = try std.posix.read(file.handle, &chunk);
        if (n == 0) break;
        if (n > limit - out.items.len) return error.FileTooLong;
        try out.appendSlice(alloc, chunk[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

/// The state script, in two parts. `envScript` writes the names fx adds to
/// every program between them. The test "the bash script keeps the reviewed
/// bytes" pins the whole script by hash, so a change to either part must update
/// that test on purpose. A multiline string has no newline after its last line,
/// so the empty last line of `body_after_skip` supplies the final one.
///
/// fx runs `. '<dir>/env.sh'` as the after-startup text of each program, so the
/// program's own shell sources this script after the user's startup definitions
/// and before the program's command. No child process gets it: no environment
/// variable names it, so a `bash -c` or a script loads no saved `set -u` and
/// saves nothing at its own exit.
///
/// The first line turns off alias expansion while the script runs, so an alias
/// the user's startup files define cannot rewrite the script's own words (a `for`
/// alias would break its loop). The startup definitions are recorded before the
/// state loads, and expansion is turned back on after it. The save never writes
/// the state's `expand_aliases` line, so the state loads with expansion off
/// whatever aliases it holds: a saved alias named `shopt` or `set` would
/// otherwise rewrite the option lines after it.
///
/// The save and the `trap` wrapper are defined before the state loads and before
/// aliases expand. Every command word in them is `builtin`, `command`, or `[[`,
/// which no function can replace, so a function or alias the program defined with
/// a word's name cannot run in its place. A program that redefines `builtin` or
/// `command` is out of scope.
///
/// The program can replace the save record with a FIFO or a link, so
/// `__fx_status_fresh` makes it an empty owner-only regular file before each write
/// of it. A write then never waits, and the next write keeps the owner-only mode.
///
/// The save also writes four temporary names: `<state>.<pid>.tmp`,
/// `<state>.<pid>.functions`, `<state>.<pid>.aliases`, and `<folder>.<pid>.tmp`.
/// A program knows its own pid, so `__fx_clear_temp` removes whatever entry is at
/// a name before the save writes it. A write then never waits, and never follows
/// a link.
///
/// The save publishes with `command -p mv`, over `$__fx_state` and `$__fx_folder`.
/// `__fx_clear_irregular` first removes a target that is a directory, a FIFO, or a
/// link, because `mv` would move the temporary file into a directory, or fail on
/// the others. A regular file stays, since `mv` replaces it atomically. Both targets
/// are cleared before the first `mv`, so a target that cannot be cleared leaves the
/// last saved state in place. A failed `mv` is a failed save, and its errors stay
/// out of the program's stderr.
const body_before_skip =
    \\\builtin shopt -u expand_aliases
    \\__fx_snapshot_env() {
    \\  builtin local IFS=$' \t\n' __fx_name
    \\  __fx_env_n=0
    \\  for __fx_name in $(builtin compgen -e); do
    \\    __fx_env_names[__fx_env_n]=$__fx_name
    \\    __fx_env_values[__fx_env_n]="${!__fx_name}"
    \\    __fx_env_n=$((__fx_env_n + 1))
    \\  done
    \\}
    \\__fx_status_fresh() {
    \\  if [[ -e "$__fx_status" || -L "$__fx_status" ]] && { [[ ! -f "$__fx_status" ]] || [[ -L "$__fx_status" ]]; }; then
    \\    command -p rm -rf -- "$__fx_status" 2>/dev/null
    \\    ( builtin umask 077; builtin printf '' >|"$__fx_status" ) 2>/dev/null
    \\  fi
    \\}
    \\__fx_clear_temp() {
    \\  if [[ -e "$1" || -L "$1" ]]; then command -p rm -rf -- "$1" 2>/dev/null; fi
    \\}
    \\__fx_clear_irregular() {
    \\  if [[ ( -e "$1" || -L "$1" ) && ( ! -f "$1" || -L "$1" ) ]]; then command -p rm -rf -- "$1" 2>/dev/null; fi
    \\}
    \\__fx_snapshot_env
    \\builtin declare -f 2>/dev/null >|"$__fx_startup_functions"
    \\builtin alias -p 2>/dev/null >|"$__fx_startup_aliases"
    \\__fx_status_fresh
    \\builtin printf 'pending\n' 2>/dev/null >|"$__fx_status"
    \\__fx_inherited() {
    \\  builtin local __fx_i=0
    \\  while [[ "$__fx_i" -lt "$__fx_env_n" ]]; do
    \\    if [[ "${__fx_env_names[__fx_i]}" = "$1" ]]; then
    \\      [[ "${__fx_env_values[__fx_i]}" = "${!1-}" ]]
    \\      builtin return
    \\    fi
    \\    __fx_i=$((__fx_i + 1))
    \\  done
    \\  builtin return 1
    \\}
    \\__fx_save() {
    \\  builtin local __fx_rc=$? __fx_name __fx_decl __fx_size __fx_tmp="$__fx_state.$$.tmp" __fx_defs_fn="$__fx_state.$$.functions" __fx_defs_al="$__fx_state.$$.aliases" __fx_keep_n=0 __fx_saved=0 __fx_nocase=0 IFS=$' \t\n'
    \\  __fx_keep=()
    \\  [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || builtin return $__fx_rc
    \\  if builtin shopt -q nocasematch; then __fx_nocase=1; builtin shopt -u nocasematch; fi
    \\  for __fx_name in $(\builtin compgen -v); do
    \\    case $__fx_name in
    \\        BASH|BASH_*|BASHOPTS|BASHPID|COLUMNS|COMP_*|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS|EUID|FUNCNAME|GROUPS|HISTCMD|HOSTNAME|HOSTTYPE|IFS|LINENO|LINES|MACHTYPE|OLDPWD|OPTERR|OPTIND|OSTYPE|PIPESTATUS|PPID|PS4|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|UID|_|__fx_*
;

/// The rest of the script, after the names fx adds to every program. The save
/// writes each function and alias the program has, and then `command -p awk` keeps
/// only the blocks whose exact text is not in the startup record. A function block
/// starts at its `name () ` line and runs to the next block's first line. An alias
/// is one record that starts with `alias `. So a definition the user's startup
/// files make, which the program leaves alone, is never saved, and the next
/// program's startup files decide it.
const body_after_skip =
    \\) builtin continue ;;
    \\    esac
    \\    __fx_inherited "$__fx_name" && builtin continue
    \\    __fx_keep[__fx_keep_n]=$__fx_name
    \\    __fx_keep_n=$((__fx_keep_n + 1))
    \\  done
    \\  __fx_clear_temp "$__fx_tmp"
    \\  __fx_clear_temp "$__fx_defs_fn"
    \\  __fx_clear_temp "$__fx_defs_al"
    \\  if (
    \\    builtin umask 077
    \\    {
    \\      if [[ "$__fx_keep_n" -gt 0 ]]; then builtin declare -p "${__fx_keep[@]}" || builtin exit 1; fi
    \\      {
    \\        for __fx_name in $(\builtin compgen -A function); do
    \\          case $__fx_name in
    \\            __fx_*|alias|builtin|cd|command|declare|eval|exec|exit|printf|set|shopt|source|trap|unalias|unset|.) builtin continue ;;
    \\          esac
    \\          builtin declare -f "$__fx_name"
    \\        done
    \\      } >|"$__fx_defs_fn"
    \\      builtin alias -p >|"$__fx_defs_al"
    \\      command -p awk -v startup_functions="$__fx_startup_functions" -v startup_aliases="$__fx_startup_aliases" '
    \\function starts(line) { return line ~ /^alias / || line ~ /^[^ ].* [(][)] $/ }
    \\function learn(path,   line, block) {
    \\    block = ""
    \\    while ((getline line < path) > 0) {
    \\        if (starts(line) && block != "") { known[block] = 1; block = "" }
    \\        block = block line "\n"
    \\    }
    \\    close(path)
    \\    if (block != "") known[block] = 1
    \\}
    \\BEGIN { learn(startup_functions); learn(startup_aliases) }
    \\{
    \\    if (starts($0) && block != "") { if (!(block in known)) printf "%s", block; block = "" }
    \\    block = block $0 "\n"
    \\}
    \\END { if (block != "" && !(block in known)) printf "%s", block }' "$__fx_defs_fn" "$__fx_defs_al" || builtin exit 1
    \\      builtin shopt -p | while builtin read -r __fx_decl; do case $__fx_decl in *' expand_aliases') builtin continue ;; esac; builtin printf '%s\n' "$__fx_decl"; done
    \\      if [[ "$__fx_nocase" -eq 1 ]]; then builtin printf 'shopt -s nocasematch\n'; fi
    \\      builtin set +o | while builtin read -r __fx_decl; do case $__fx_decl in *' errexit'|*' posix'|*' xtrace') ;; *) builtin printf '%s\n' "$__fx_decl" ;; esac; done
    \\    } 2>/dev/null >|"$__fx_tmp"
    \\  ); then
    \\    __fx_size=$(( $(\command -p wc -c <"$__fx_tmp") ))
    \\    if [[ "$__fx_size" -gt "$__fx_max" ]]; then
    \\      command -p rm -f "$__fx_tmp" 2>/dev/null
    \\      ( builtin umask 077; __fx_status_fresh; builtin printf 'cap %s\n' "$__fx_size" >|"$__fx_status" ) 2>/dev/null
    \\      __fx_saved=1
    \\    elif ( builtin umask 077; __fx_clear_temp "$__fx_folder.$$.tmp"; builtin printf '%s' "$PWD" >|"$__fx_folder.$$.tmp" ) 2>/dev/null &&
    \\      __fx_clear_irregular "$__fx_state" && __fx_clear_irregular "$__fx_folder" &&
    \\      command -p mv -f "$__fx_tmp" "$__fx_state" 2>/dev/null && command -p mv -f "$__fx_folder.$$.tmp" "$__fx_folder" 2>/dev/null; then
    \\      __fx_saved=1
    \\      __fx_status_fresh
    \\      builtin printf '' 2>/dev/null >|"$__fx_status"
    \\    fi
    \\  fi
    \\  command -p rm -f "$__fx_defs_fn" "$__fx_defs_al" 2>/dev/null
    \\  if [[ "$__fx_saved" -eq 0 ]]; then
    \\    command -p rm -f "$__fx_tmp" "$__fx_folder.$$.tmp" 2>/dev/null
    \\    if [[ -d "${__fx_state%/*}" ]]; then
    \\      ( builtin umask 077; __fx_status_fresh; builtin printf 'failed\n' >|"$__fx_status" ) 2>/dev/null
    \\    fi
    \\  fi
    \\  if [[ "$__fx_nocase" -eq 1 ]]; then builtin shopt -s nocasematch; fi
    \\  builtin return $__fx_rc
    \\}
    \\trap() {
    \\  builtin trap "$@" || builtin return $?
    \\  builtin local __fx_line
    \\  __fx_line=$(\builtin trap -p EXIT)
    \\  if [[ -z "$__fx_line" ]]; then
    \\    builtin trap '{ __fx_save; } 2>/dev/null' EXIT
    \\    builtin return 0
    \\  fi
    \\  builtin eval "\builtin set -- $__fx_line"
    \\  case $3 in
    \\    "{ __fx_save; } 2>/dev/null"|"{ __fx_save; } 2>/dev/null"$'\n'*) builtin return 0 ;;
    \\  esac
    \\  builtin trap "{ __fx_save; } 2>/dev/null
    \\$3" EXIT
    \\}
    \\if [[ -f "$__fx_state" && ! -L "$__fx_state" ]]; then builtin . "$__fx_state" >/dev/null 2>&1; fi
    \\\builtin shopt -s expand_aliases
    \\\builtin trap '{ __fx_save; } 2>/dev/null' EXIT
    \\
;

test "wait_more is the whole code, ignoring spaces and line ends" {
    try std.testing.expect(isWaitMore("wait_more"));
    try std.testing.expect(isWaitMore(" wait_more\n"));
    try std.testing.expect(!isWaitMore("wait_more; ls"));
    try std.testing.expect(!isWaitMore("echo wait_more"));
    try std.testing.expect(!isWaitMore(""));
}

test "bashPath keeps an absolute bash and falls back to /bin/bash" {
    try std.testing.expectEqualStrings("/usr/local/bin/bash", bashPath("/usr/local/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", bashPath("/bin/zsh"));
    try std.testing.expectEqualStrings("/bin/bash", bashPath(null));
    try std.testing.expectEqualStrings("/bin/bash", bashPath("bash"));
}

test "envScript quotes the state path, keeps the header, and installs the save trap" {
    const alloc = std.testing.allocator;
    const script = try envScript(alloc, "/tmp/a'b/state.sh", "/tmp/a'b/folder", "/tmp/a'b/startup-functions", "/tmp/a'b/startup-aliases", "/tmp/a'b/save-status", &test_fx_variables);
    defer alloc.free(script);
    var lines = std.mem.splitScalar(u8, script, '\n');
    try std.testing.expectEqualStrings("# fx bash tool: load the bash state the last program saved, and save it again", lines.next().?);
    try std.testing.expectEqualStrings("# when this program ends (tests/tla/bash_tool/ResultStore.tla Finish).", lines.next().?);
    try std.testing.expectEqualStrings("__fx_state='/tmp/a'\\''b/state.sh'", lines.next().?);
    try std.testing.expectEqualStrings("__fx_folder='/tmp/a'\\''b/folder'", lines.next().?);
    try std.testing.expectEqualStrings("__fx_startup_functions='/tmp/a'\\''b/startup-functions'", lines.next().?);
    try std.testing.expectEqualStrings("__fx_startup_aliases='/tmp/a'\\''b/startup-aliases'", lines.next().?);
    try std.testing.expectEqualStrings("__fx_status='/tmp/a'\\''b/save-status'", lines.next().?);
    try std.testing.expect(std.mem.find(u8, script, "trap '{ __fx_save; } 2>/dev/null' EXIT\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, script, "\\builtin trap '{ __fx_save; } 2>/dev/null' EXIT\n"));
}

test "the bash script keeps the reviewed bytes" {
    const script = try envScript(std.testing.allocator, "/tmp/fx-pinned/state.sh", "/tmp/fx-pinned/folder", "/tmp/fx-pinned/startup-functions", "/tmp/fx-pinned/startup-aliases", "/tmp/fx-pinned/save-status", &test_fx_variables);
    defer std.testing.allocator.free(script);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("ab93a7243fd020ff46c019f49e9b8da204c51c96a298b368face88649455a8b3", &hex);
}

test "prepare refuses a relative temp root and leaves no session" {
    var session = Session.init(std.testing.allocator);
    try std.testing.expectError(error.RelativeTmpRoot, session.prepare(std.testing.io, "relative/root", &.{}));
    try std.testing.expect(session.dir == null);
}

test "deinit deletes the session folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    _ = try session.prepare(io, root, &.{});
    const dir = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(dir);
    _ = session.deinit(io);
    try std.testing.expect(session.dir == null and session.after_startup == null);
    if (std.Io.Dir.cwd().openDir(io, dir, .{})) |opened| {
        var folder = opened;
        folder.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

const program_one =
    \\x="two words"; export Y=exported; arr=(a "b c"); f() { echo "f says $1"; }; alias ll="echo alias-ok"; shopt -s nullglob; set -u; set -e; cd "sub dir"; exit 3
;
const program_two =
    \\echo "x=$x Y=$Y arr1=${arr[1]} pwd=$(basename "$PWD")"; f hi; ll; shopt -q nullglob && echo nullglob-on; [[ $- == *u* ]] && echo nounset-on; [[ $- == *e* ]] && echo errexit-on || echo errexit-off; echo token=$FX_MCP_CALL_TOKEN
;
const program_three =
    \\x=changed; kill -9 $$
;
const program_four =
    \\echo "x=$x"
;
const expected_two = "x=two words Y=exported arr1=b c pwd=sub dir\nf says hi\nalias-ok\nnullglob-on\nnounset-on\nerrexit-off\ntoken=t2\n";

/// Runs `program` as one bash tool program of `session`, in `cwd`, with the
/// environment a program gets: PATH and the call token. The caller frees the
/// result with `freeRun`.
fn runProgram(alloc: std.mem.Allocator, io: std.Io, session: *const Session, cwd: []const u8, token: []const u8, program: []const u8) !std.process.RunResult {
    return runProgramAfterStartup(alloc, io, session, cwd, token, "", &.{}, program);
}

/// Runs `program` like `runProgram`, with `extra` added to the environment the
/// program inherits, as fx's own environment would pass it.
fn runProgramWithEnv(alloc: std.mem.Allocator, io: std.Io, session: *const Session, cwd: []const u8, token: []const u8, extra: []const [2][]const u8, program: []const u8) !std.process.RunResult {
    return runProgramAfterStartup(alloc, io, session, cwd, token, "", extra, program);
}

/// Runs `program` as fx runs a bash tool program: one `bash -c` string, with
/// `expand_aliases`, that holds `startup` (which stands in for the user's startup
/// definitions), then the session's after-startup text, then the program. The
/// caller frees the result with `freeRun`.
fn runProgramAfterStartup(alloc: std.mem.Allocator, io: std.Io, session: *const Session, cwd: []const u8, token: []const u8, startup: []const u8, extra: []const [2][]const u8, program: []const u8) !std.process.RunResult {
    const after = session.afterStartupText() orelse return error.TestNoAfterStartup;
    const script = try alloc.print("{s}\n{s}\n{s}", .{ startup, after, program });
    defer alloc.free(script);
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("FX_MCP_CALL_TOKEN", token);
    for (extra) |pair| try environ.put(pair[0], pair[1]);
    return std.process.run(alloc, io, .{
        .argv = &.{ "/bin/bash", "--noprofile", "--norc", "-O", "expand_aliases", "-c", script },
        .cwd = .{ .path = cwd },
        .environ_map = &environ,
    });
}

/// Whether `folder` takes a new file despite its mode, as for root or a user with
/// the DAC override capability. A test that needs a refused write cannot fail then,
/// so it skips. The probe is a real create, since `access` answers for the real
/// user and disagrees with the kernel here.
fn modeIgnored(io: std.Io, folder: std.Io.Dir) bool {
    const file = folder.createFile(io, "mode-probe", .{ .exclusive = true }) catch return false;
    file.close(io);
    folder.deleteFile(io, "mode-probe") catch {}; // Best effort: the probe file is removed with the test's folder.
    return true;
}

/// Makes a FIFO at `path` with the `mkfifo` tool, since std has no call for it.
/// The tests that use it run where `/bin/bash` exists, so POSIX.
fn makeFifo(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const result = try std.process.run(alloc, io, .{ .argv = &.{ "/usr/bin/mkfifo", path } });
    defer freeRun(alloc, result);
    try expectExit(result, 0);
}

/// Makes `path` a second name for `target`, a hard link, with the `ln` tool, since
/// std has no call for it.
fn makeHardLink(alloc: std.mem.Allocator, io: std.Io, target: []const u8, path: []const u8) !void {
    const result = try std.process.run(alloc, io, .{ .argv = &.{ "/bin/ln", target, path } });
    defer freeRun(alloc, result);
    try expectExit(result, 0);
}

/// Whether `healed` made the repair `what` to the file `name`.
fn healedHas(healed: *const Healed, what: RepairKind, name: []const u8) bool {
    for (healed.items()) |repair| {
        if (repair.what == what and std.mem.eql(u8, repair.name, name)) return true;
    }
    return false;
}

fn freeRun(alloc: std.mem.Allocator, result: std.process.RunResult) void {
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// Fails unless the program exited with `code`. On a mismatch it prints the
/// program's stderr, so the cause shows in the test output.
fn expectExit(result: std.process.RunResult, code: u8) !void {
    switch (result.term) {
        .exited => |actual| if (actual != code) {
            std.debug.print("exit {d}, want {d}; stderr: {s}\n", .{ actual, code, result.stderr });
            return error.TestUnexpectedExit;
        },
        else => {
            std.debug.print("not an exit; stderr: {s}\n", .{result.stderr});
            return error.TestUnexpectedExit;
        },
    }
}

test "a bash tool program saves its state for the next, and a killed one saves nothing" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.createDir(io, "sub dir", .default_dir);

    const first = try runProgram(alloc, io, &session, dir, "t1", program_one);
    defer freeRun(alloc, first);
    try expectExit(first, 3);

    // fx starts each program in the folder the last saved program ended in.
    _ = session.refreshStartFolder(io);
    const start = session.startFolder() orelse dir;

    const second = try runProgram(alloc, io, &session, start, "t2", program_two);
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings(expected_two, second.stdout);

    const third = try runProgram(alloc, io, &session, start, "t3", program_three);
    defer freeRun(alloc, third);
    switch (third.term) {
        .signal => {},
        else => return error.TestUnexpectedExit,
    }

    const fourth = try runProgram(alloc, io, &session, start, "t4", program_four);
    defer freeRun(alloc, fourth);
    try expectExit(fourth, 0);
    try std.testing.expectEqualStrings("x=two words\n", fourth.stdout);

    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "FX_MCP_CALL_TOKEN") == null);
    try std.testing.expect(std.mem.find(u8, state, "declare -r") == null);
}

test "a program's own EXIT trap keeps fx's save, and its handler sees the exit status" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const bye = try runProgram(alloc, io, &session, dir, "trap1", "trap 'echo \"bye rc=$?\"' EXIT; a=1");
    defer freeRun(alloc, bye);
    try expectExit(bye, 0);
    try std.testing.expectEqualStrings("bye rc=0\n", bye.stdout);

    const sees_a = try runProgram(alloc, io, &session, dir, "trap2", "echo \"a=$a\"");
    defer freeRun(alloc, sees_a);
    try expectExit(sees_a, 0);
    try std.testing.expectEqualStrings("a=1\n", sees_a.stdout);

    const exits = try runProgram(alloc, io, &session, dir, "trap3", "trap 'exit 3' EXIT; b=2");
    defer freeRun(alloc, exits);
    try expectExit(exits, 3);

    const sees_b = try runProgram(alloc, io, &session, dir, "trap4", "echo \"b=$b\"");
    defer freeRun(alloc, sees_b);
    try expectExit(sees_b, 0);
    try std.testing.expectEqualStrings("b=2\n", sees_b.stdout);

    const reset = try runProgram(alloc, io, &session, dir, "trap5", "trap - EXIT; c=3");
    defer freeRun(alloc, reset);
    try expectExit(reset, 0);

    const sees_c = try runProgram(alloc, io, &session, dir, "trap6", "echo \"a=$a b=$b c=$c\"");
    defer freeRun(alloc, sees_c);
    try expectExit(sees_c, 0);
    try std.testing.expectEqualStrings("a=1 b=2 c=3\n", sees_c.stdout);
}

test "a subshell that sets its own EXIT trap never saves state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const sub = try runProgram(alloc, io, &session, dir, "sub1", "( trap 'true' EXIT; d=4 ); e=5");
    defer freeRun(alloc, sub);
    try expectExit(sub, 0);

    const sees = try runProgram(alloc, io, &session, dir, "sub2", "echo \"d=${d:-none} e=$e\"");
    defer freeRun(alloc, sees);
    try expectExit(sees, 0);
    try std.testing.expectEqualStrings("d=none e=5\n", sees.stdout);
}

test "a subshell's state is never kept when its program is killed after it" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The main shell never saves after kill -9, so only a subshell's save could keep d.
    const killed = try runProgram(alloc, io, &session, dir, "subkill1", "( trap 'true' EXIT; d=4 ); e=5; kill -9 $$");
    defer freeRun(alloc, killed);
    switch (killed.term) {
        .signal => {},
        else => return error.TestUnexpectedExit,
    }

    const sees = try runProgram(alloc, io, &session, dir, "subkill2", "echo \"d=${d:-none} e=${e:-none}\"");
    defer freeRun(alloc, sees);
    try expectExit(sees, 0);
    try std.testing.expectEqualStrings("d=none e=none\n", sees.stdout);
}

test "variables fx passes in are never saved, and the program's own exports are" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const inherited = try runProgramWithEnv(alloc, io, &session, dir, "env1", &.{.{ "SECRET_TOKEN", "xyz" }}, "echo \"got=$SECRET_TOKEN\"");
    defer freeRun(alloc, inherited);
    try expectExit(inherited, 0);
    try std.testing.expectEqualStrings("got=xyz\n", inherited.stdout);

    const exported = try runProgram(alloc, io, &session, dir, "env2", "export MINE=1");
    defer freeRun(alloc, exported);
    try expectExit(exported, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "xyz") == null);
    try std.testing.expect(std.mem.find(u8, state, "MINE=\"1\"") != null);
}

test "the saved state is readable by its owner only" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const run = try runProgram(alloc, io, &session, dir, "mode1", "x=1");
    defer freeRun(alloc, run);
    try expectExit(run, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const stat = try folder.statFile(io, "state.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "a program that sets 300 variables has all of them restored" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const set = try runProgram(alloc, io, &session, dir, "many1", "for ((i = 1; i <= 300; i++)); do eval \"v$i=$i\"; done");
    defer freeRun(alloc, set);
    try expectExit(set, 0);

    const check = try runProgram(alloc, io, &session, dir, "many2", "n=0; for ((i = 1; i <= 300; i++)); do eval \"x=\\${v$i}\"; [ \"$x\" = \"$i\" ] && n=$((n + 1)); done; echo \"n=$n\"");
    defer freeRun(alloc, check);
    try expectExit(check, 0);
    try std.testing.expectEqualStrings("n=300\n", check.stdout);
}

test "the start folder is the folder the last saved program ended in" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const moved = try runProgram(alloc, io, &session, dir, "folder1", "cd /");
    defer freeRun(alloc, moved);
    try expectExit(moved, 0);

    _ = session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);
}

test "a program over the size cap leaves the start folder unchanged" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "folder2", "cd /");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    _ = session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);

    const big = try runProgram(alloc, io, &session, dir, "folder3", "cd /tmp; big=$(head -c 1100000 /dev/zero | tr '\\0' a)");
    defer freeRun(alloc, big);
    try expectExit(big, 0);
    try std.testing.expectEqualStrings("", big.stderr);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => |bytes| try std.testing.expect(bytes > max_state_bytes),
        .failed, .not_saved => return error.TestUnexpectedFailedSave,
    }

    _ = session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);
}

test "a folder file that names a removed directory gives no start folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    try std.testing.expectEqual(StartFolderStatus.no_record, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = "/fx-bash-no-such-folder" });
    try std.testing.expectEqual(StartFolderStatus.gone, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);
}

test "refreshStartFolder says why it kept or dropped the saved folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);

    // A fresh session has no folder file yet: the normal case, which is not a drop.
    try std.testing.expectEqual(StartFolderStatus.no_record, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);

    // A folder that exists is kept.
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = root });
    try std.testing.expectEqual(StartFolderStatus.kept, session.refreshStartFolder(io));
    try std.testing.expectEqualStrings(root, session.startFolder() orelse return error.TestNoStartFolder);

    // A folder that no longer exists is gone.
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = "/fx-bash-no-such-folder" });
    try std.testing.expectEqual(StartFolderStatus.gone, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);

    // A folder file that names a regular file is gone too: that is not a directory.
    try tmp.dir.writeFile(io, .{ .sub_path = "a-file", .data = "x" });
    const file_path = try alloc.print("{s}/a-file", .{root});
    defer alloc.free(file_path);
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = file_path });
    try std.testing.expectEqual(StartFolderStatus.gone, session.refreshStartFolder(io));

    // A relative path, a NUL byte, or a path too long for the limit is a bad record.
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = "relative/dir" });
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = "/tmp/a\x00b" });
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    var long: [std.Io.Dir.max_path_bytes + 1]u8 = @splat('a');
    long[0] = '/';
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = &long });
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));

    // A directory in place of the folder file is not a regular file.
    try folder.deleteFile(io, folder_file);
    try folder.createDirPath(io, folder_file);
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);
}

test "the saved state holds no cd line" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const moved = try runProgram(alloc, io, &session, dir, "folder4", "cd /");
    defer freeRun(alloc, moved);
    try expectExit(moved, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "cd --") == null);
}

test "prepare refuses a temp root with a dollar sign, a backquote, or a backslash" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    for ([_][]const u8{ "/tmp/a$b", "/tmp/a`b", "/tmp/a\\b" }) |root| {
        try std.testing.expectError(error.UnsafeTmpRoot, session.prepare(io, root, &.{}));
        try std.testing.expect(session.dir == null);
    }
}

test "a child bash of a program does not load the saved state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const set = try runProgram(alloc, io, &session, dir, "set-u", "set -u");
    defer freeRun(alloc, set);
    try expectExit(set, 0);

    // The child would die on the unset name if it had loaded the saved `set -u`.
    const child = try runProgram(alloc, io, &session, dir, "child", "bash -c 'echo \"${NOT_SET_ANYWHERE}x\"'");
    defer freeRun(alloc, child);
    try expectExit(child, 0);
    try std.testing.expectEqualStrings("x\n", child.stdout);
}

test "a child bash of a program changes neither the saved state nor the folder" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The EXIT handler runs after fx saves, so this child is the last thing that could save.
    const run = try runProgram(alloc, io, &session, dir, "child-exit", "trap \"bash -c 'cd /; Z=child'\" EXIT; echo ran");
    defer freeRun(alloc, run);
    try expectExit(run, 0);
    try std.testing.expectEqualStrings("ran\n", run.stdout);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "Z=") == null);
    const saved_folder = try folder.readFileAlloc(io, folder_file, alloc, .limited(std.Io.Dir.max_path_bytes));
    defer alloc.free(saved_folder);
    try std.testing.expectEqualStrings(dir, saved_folder);
}

test "a background child that ends after its program changes neither the saved state nor the folder" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The program makes two fifos. A background subshell waits on the first, then
    // runs a `bash -c` child, then writes the second once that child has ended.
    const gate = try alloc.print("{s}/gate", .{dir});
    defer alloc.free(gate);
    const done = try alloc.print("{s}/done", .{dir});
    defer alloc.free(done);
    const start = try alloc.print(
        "mkfifo '{s}' '{s}'; Y=kept; mkdir -p sub && cd sub; ( read go < '{s}'; bash -c 'cd /; Z=late'; echo ended > '{s}' ) </dev/null >/dev/null 2>&1 &",
        .{ gate, done, gate, done },
    );
    defer alloc.free(start);
    const started = try runProgram(alloc, io, &session, dir, "late-child", start);
    defer freeRun(alloc, started);
    try expectExit(started, 0);

    // Release the child, then wait for it to end. Both fifos are opened read-write,
    // so no open waits for the other side: the gate's line waits in the pipe until
    // the subshell reads it, and `read -t` bounds the wait to 10 seconds. The test
    // never sleeps and never blocks.
    const release = try alloc.print(
        "exec 4<>'{s}' && echo go >&4 && exec 3<>'{s}' && read -t 10 ok <&3",
        .{ gate, done },
    );
    defer alloc.free(release);
    const released = try std.process.run(alloc, io, .{ .argv = &.{ "/bin/bash", "--noprofile", "--norc", "-c", release } });
    defer freeRun(alloc, released);
    try expectExit(released, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "Z=") == null);
    try std.testing.expect(std.mem.find(u8, state, "kept") != null);
    const saved_folder = try folder.readFileAlloc(io, folder_file, alloc, .limited(std.Io.Dir.max_path_bytes));
    defer alloc.free(saved_folder);
    const sub = try alloc.print("{s}/sub", .{dir});
    defer alloc.free(sub);
    try std.testing.expectEqualStrings(sub, saved_folder);
}

/// Fails when the session folder holds a file whose name ends in `.tmp`: a save
/// that works renames its temporary file away.
fn expectNoTmpFile(io: std.Io, dir: []const u8) !void {
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer folder.close(io);
    var entries = folder.iterate();
    while (try entries.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".tmp")) return error.TmpFileLeftBehind;
    }
}

test "a program's functions and aliases named like the save's words do not stop the save" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // Each word the save uses is a function that does nothing, and an alias that
    // would print. `wc` prints a size over the cap, which would be a false notice.
    const shadow =
        "mv() { :; }; rm() { :; }; wc() { echo 9999999; }; read() { :; }; printf() { :; }; " ++
        "compgen() { :; }; declare() { :; }; alias() { :; }; shopt() { :; }; set() { :; }; " ++
        "umask() { :; }; test() { :; }; [() { :; }; " ++
        "builtin alias mv='echo hijacked' rm='echo hijacked' wc='echo hijacked' read='echo hijacked' " ++
        "printf='echo hijacked' compgen='echo hijacked' declare='echo hijacked' alias='echo hijacked' " ++
        "shopt='echo hijacked' set='echo hijacked' umask='echo hijacked' test='echo hijacked' " ++
        "'['='echo hijacked'; kept=1";
    const first = try runProgram(alloc, io, &session, dir, "shadow", shadow);
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);

    const second = try runProgram(alloc, io, &session, dir, "after-shadow", "echo \"kept=$kept\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("kept=1\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);
    try expectNoTmpFile(io, dir);
}

test "a state that cannot be written is not saved, and the save records why" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    // A read-only folder stops a create. A user with a DAC-override capability, or root, still creates in it,
    // so the test skips for that user, as the permission tests do.
    try tmp.dir.createDirPath(io, "probe");
    var probe = try tmp.dir.openDir(io, "probe", .{ .iterate = true });
    defer probe.close(io);
    try probe.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    defer probe.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the probe is restored so the temporary directory can be removed.
    if (modeIgnored(io, probe)) return error.SkipZigTest;

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var session_folder = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer session_folder.close(io);
    defer session_folder.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the folder is restored so the test's folder can be removed.

    const first = try runProgram(alloc, io, &session, dir, "first", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    // The program makes its session folder read-only, so the save cannot create its temporary file.
    // The write fails while the folder still exists.
    const second = try runProgram(alloc, io, &session, dir, "blocked", "x=2; /bin/chmod 500 \"${__fx_state%/*}\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("", second.stderr);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => return error.TestUnexpectedOverCap,
        .failed => {},
        .not_saved => return error.TestUnexpectedStatus,
    }
    try session_folder.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));

    const third = try runProgram(alloc, io, &session, dir, "after-blocked", "echo \"x=$x\"");
    defer freeRun(alloc, third);
    try expectExit(third, 0);
    try std.testing.expectEqualStrings("x=1\n", third.stdout);
}

test "a program's alias for a name the startup defines carries to the next program" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const startup = "alias ll='echo RC'";
    const first = try runProgramAfterStartup(alloc, io, &session, dir, "alias1", startup, &.{}, "alias ll='echo MINE'");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "alias2", startup, &.{}, "ll");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("MINE\n", second.stdout);
}

test "a startup function the program leaves alone is not saved" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const startup = "f() { echo RC; }";
    const first = try runProgramAfterStartup(alloc, io, &session, dir, "keep1", startup, &.{}, "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "x=\"1\"") != null);
    try std.testing.expect(std.mem.find(u8, state, "f () ") == null);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "keep2", startup, &.{}, "f; echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("RC\nx=1\n", second.stdout);
}

test "a startup function the program never defined takes the next startup's definition" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgramAfterStartup(alloc, io, &session, dir, "startup-a", "g() { echo A; }", &.{}, "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "startup-b", "g() { echo B; }", &.{}, "g");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("B\n", second.stdout);
}

test "a startup alias named like a word of the script does not stop the save" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // Without the first line of the script, this alias would expand the script's
    // own `for` loop, the script would not load, and nothing would be saved.
    const startup = "alias for='echo H'";
    const first = try runProgramAfterStartup(alloc, io, &session, dir, "reserved1", startup, &.{}, "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "reserved2", startup, &.{}, "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "prepare makes the startup records owner-only, and the after-startup text sources env.sh" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    inline for (.{ startup_functions_file, startup_aliases_file }) |name| {
        const stat = try folder.statFile(io, name, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    const want = try alloc.print("\\builtin . '{s}/env.sh'", .{dir});
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, session.afterStartupText() orelse return error.TestNoAfterStartup);
}

test "startup aliases named like the script's own words do not stop the save" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // Each alias would print BAD wherever the script let it expand: the after-startup
    // `.`, the script's own lines and `$()` words, and the trap wrapper, which the
    // program reaches with `\trap`.
    const startup = "alias builtin='echo BAD'; alias command='echo BAD'; alias .='echo BAD'; alias shopt='echo BAD'; alias trap='echo BAD'";
    const first = try runProgramAfterStartup(alloc, io, &session, dir, "words1", startup, &.{}, "\\trap 'true' EXIT; kept=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stdout);
    try std.testing.expectEqualStrings("", first.stderr);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "words2", startup, &.{}, "echo \"kept=$kept\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("kept=1\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);
}

test "setting a program twice frees the first id" {
    var session = Session.init(std.testing.allocator);
    defer _ = session.deinit(std.testing.io);
    try session.setProgram("first");
    try session.setProgram("second");
    try std.testing.expectEqualStrings("second", session.program().?);
}

test "deinit frees the program id and leaves none" {
    var session = Session.init(std.testing.allocator);
    try session.setProgram("first");
    _ = session.deinit(std.testing.io);
    try std.testing.expect(session.program() == null);
}

test "prepare removes a folder a dead process left in the temp root" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.createDir(io, "fx-bash-2147483646-dead", .default_dir);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "fx-bash-2147483646-dead", .{}));
}

test "prepare keeps the folders of this process and of a live process" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const own_name = try alloc.print("fx-bash-{d}-live", .{processId()});
    defer alloc.free(own_name);
    try tmp.dir.createDir(io, own_name, .default_dir);
    try tmp.dir.createDir(io, "fx-bash-1-live", .default_dir);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try tmp.dir.access(io, own_name, .{});
    try tmp.dir.access(io, "fx-bash-1-live", .{});
}

test "prepare never follows or removes a link named like a bash folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.createDir(io, "target", .default_dir);
    var target = try tmp.dir.openDir(io, "target", .{});
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "keep.txt", .data = "kept" });
    const target_path = try alloc.print("{s}/target", .{root});
    defer alloc.free(target_path);
    try tmp.dir.symLink(io, target_path, "fx-bash-2147483646-link", .{ .is_directory = true });

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &.{});

    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(io, "fx-bash-2147483646-link", &link_buffer);
    const kept = try target.readFileAlloc(io, "keep.txt", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("kept", kept);
}

test "prepare keeps a file named like a bash folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "fx-bash-2147483646-file", .data = "x" });

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try tmp.dir.access(io, "fx-bash-2147483646-file", .{});
}

test "a new bash folder is named with this process's id" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    const name = std.Io.Dir.path.basename(session.dir.?);
    const prefix = try alloc.print("fx-bash-{d}-", .{processId()});
    defer alloc.free(prefix);
    try std.testing.expect(std.mem.startsWith(u8, name, prefix));
    try std.testing.expectEqual(@as(usize, 16), name.len - prefix.len);
    try std.testing.expectEqual(processId(), folderOwner(name).?);
}

/// The names the tests pass as fx's own: the same three `bash.zig` passes.
const test_fx_variables = [_][]const u8{ "AI_AGENT", "FX_MCP_CALL_SOCKET", "FX_MCP_CALL_TOKEN" };

test "a state over the size cap is not saved, and the save records why" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "big1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const big = try runProgram(alloc, io, &session, dir, "big2", "big=$(head -c 1100000 /dev/zero | tr '\\0' a)");
    defer freeRun(alloc, big);
    try expectExit(big, 0);
    try std.testing.expectEqualStrings("", big.stderr);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => |bytes| try std.testing.expect(bytes > max_state_bytes),
        .failed, .not_saved => return error.TestUnexpectedFailedSave,
    }

    const after = try runProgram(alloc, io, &session, dir, "big3", "echo \"x=${x:-unset} big=${big:-none}\"");
    defer freeRun(alloc, after);
    try expectExit(after, 0);
    try std.testing.expectEqualStrings("x=1 big=none\n", after.stdout);
}

test "the save records an over-cap state, and a state it keeps leaves no record" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const kept = try runProgram(alloc, io, &session, dir, "kept", "x=1");
    defer freeRun(alloc, kept);
    try expectExit(kept, 0);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const big = try runProgram(alloc, io, &session, dir, "big", "big=$(head -c 1100000 /dev/zero | tr '\\0' a)");
    defer freeRun(alloc, big);
    try expectExit(big, 0);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => |bytes| try std.testing.expect(bytes > max_state_bytes),
        .failed, .not_saved => return error.TestUnexpectedFailedSave,
    }
    // Taking the record deletes it, so the next take finds none.
    try std.testing.expect(session.takeSaveStatus(io) == null);
}

test "a save record is read as the save wrote it, and any other record counts as failed" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);

    try folder.writeFile(io, .{ .sub_path = "save-status", .data = "cap 42\n" });
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => |bytes| try std.testing.expectEqual(@as(usize, 42), bytes),
        .failed, .not_saved => return error.TestUnexpectedFailedSave,
    }

    try folder.writeFile(io, .{ .sub_path = "save-status", .data = "failed\n" });
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => return error.TestUnexpectedOverCap,
        .failed => {},
        .not_saved => return error.TestUnexpectedStatus,
    }

    try folder.writeFile(io, .{ .sub_path = "save-status", .data = "cap lots\n" });
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => return error.TestUnexpectedOverCap,
        .failed => {},
        .not_saved => return error.TestUnexpectedStatus,
    }

    try folder.writeFile(io, .{ .sub_path = "save-status", .data = "pending\n" });
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .not_saved => {},
        .over_cap, .failed => return error.TestUnexpectedStatus,
    }

    // The take empties the record, so the next take finds nothing to report.
    try std.testing.expect(session.takeSaveStatus(io) == null);
}

test "a program that runs trap - EXIT ends without its save, and its record says not saved" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "untrapped1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgram(alloc, io, &session, dir, "untrapped2", "builtin trap - EXIT; x=2");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("", second.stderr);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .not_saved => {},
        .over_cap, .failed => return error.TestUnexpectedStatus,
    }

    const third = try runProgram(alloc, io, &session, dir, "untrapped3", "echo \"x=$x\"");
    defer freeRun(alloc, third);
    try expectExit(third, 0);
    try std.testing.expectEqualStrings("x=1\n", third.stdout);
}

test "a program that runs exec ends without its save, and its record says not saved" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "exec1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgram(alloc, io, &session, dir, "exec2", "x=2; exec true");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .not_saved => {},
        .over_cap, .failed => return error.TestUnexpectedStatus,
    }

    const third = try runProgram(alloc, io, &session, dir, "exec3", "echo \"x=$x\"");
    defer freeRun(alloc, third);
    try expectExit(third, 0);
    try std.testing.expectEqualStrings("x=1\n", third.stdout);
}

test "a program killed with SIGKILL ends without its save, and its record says not saved" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "killed1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const second = try runProgram(alloc, io, &session, dir, "killed2", "x=2; kill -9 $$");
    defer freeRun(alloc, second);
    switch (second.term) {
        .signal => |signal| try std.testing.expectEqual(std.posix.SIG.KILL, signal),
        else => return error.TestUnexpectedExit,
    }
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .not_saved => {},
        .over_cap, .failed => return error.TestUnexpectedStatus,
    }

    const third = try runProgram(alloc, io, &session, dir, "killed3", "echo \"x=$x\"");
    defer freeRun(alloc, third);
    try expectExit(third, 0);
    try std.testing.expectEqualStrings("x=1\n", third.stdout);
}

test "a program that sets xtrace is traced, and the save adds no line to its output" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "xtrace1", "set -x; y=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stdout);
    try std.testing.expect(std.mem.find(u8, first.stderr, "+ y=1") != null);
    try std.testing.expect(std.mem.find(u8, first.stderr, "__fx_") == null);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    // xtrace is not part of the saved state, so the next program is not traced.
    const second = try runProgram(alloc, io, &session, dir, "xtrace2", "echo \"y=$y\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("y=1\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);
}

test "a program's own EXIT trap gets fx's save once, and a trap on another signal adds none" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // `trap -p` prints the EXIT trap, so the save's text shows once; the handler runs last.
    const run = try runProgram(alloc, io, &session, dir, "once1", "x=1; trap 'echo bye' EXIT; trap - INT; builtin trap -p EXIT");
    defer freeRun(alloc, run);
    try expectExit(run, 0);
    const first_save = std.mem.find(u8, run.stdout, "__fx_save") orelse return error.TestNoSaveInTrap;
    try std.testing.expect(std.mem.find(u8, run.stdout[first_save + "__fx_save".len ..], "__fx_save") == null);
    try std.testing.expect(std.mem.endsWith(u8, run.stdout, "EXIT\nbye\n"));
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const next = try runProgram(alloc, io, &session, dir, "once2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a program's own EXIT handler still traces after the save" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The handler is set before xtrace is on, so the trap wrapper's own lines are not traced.
    // The save never turns xtrace off, so the handler traces.
    const run = try runProgram(alloc, io, &session, dir, "handler1", "trap 'echo HANDLER' EXIT; set -x; y=1");
    defer freeRun(alloc, run);
    try expectExit(run, 0);
    try std.testing.expectEqualStrings("HANDLER\n", run.stdout);
    try std.testing.expect(std.mem.find(u8, run.stderr, "+ echo HANDLER") != null);
    try std.testing.expect(std.mem.find(u8, run.stderr, "__fx_") == null);
}

test "a program that sets IFS to a tab keeps its state, and the save writes no notice" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "ifs1", "IFS=$'\\t'; x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const second = try runProgram(alloc, io, &session, dir, "ifs2", "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a program that sets IFS to letters keeps its state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "letters-ifs1", "IFS=abc; x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const second = try runProgram(alloc, io, &session, dir, "letters-ifs2", "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a program that sets IFS to nothing keeps its state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "empty-ifs1", "IFS=; x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const second = try runProgram(alloc, io, &session, dir, "empty-ifs2", "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a program that sets nocasematch keeps the variables of the next program" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "nocase1", "shopt -s nocasematch; x=1; hostname=kept");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    // The option is part of the program's state, so the next program has it on too.
    const second = try runProgram(alloc, io, &session, dir, "nocase2", "echo \"x=$x h=$hostname\"; if shopt -q nocasematch; then echo on; else echo off; fi");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1 h=kept\non\n", second.stdout);
}

test "a saved alias named shopt, set, declare, or alias leaves the next program's options alone" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The aliases come after the settings, as in the review's probe r9, so the
    // settings are made before any of the four words is aliased.
    const first = try runProgram(alloc, io, &session, dir, "alias1", "shopt -s nocasematch extglob\nset -u\nx=1\nf() { echo F; }\nalias ll='echo LL'\nalias shopt=:\nalias set=:\nalias declare=:\nalias alias=:");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    // The second program uses `builtin` and `[[`, never the four aliased words.
    const second = try runProgram(alloc, io, &session, dir, "alias2", "builtin shopt -q nocasematch && echo nc=on || echo nc=off\nbuiltin shopt -q extglob && echo eg=on || echo eg=off\n[[ $- == *u* ]] && echo u=on || echo u=off\necho \"x=$x\"\nf\nll");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("nc=on\neg=on\nu=on\nx=1\nF\nLL\n", second.stdout);
}

test "a folder file that is a FIFO is a bad record: the start folder is the workspace root, and the call returns" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const folder_path = try alloc.print("{s}/{s}", .{ session.dir.?, folder_file });
    defer alloc.free(folder_path);
    try makeFifo(alloc, io, folder_path);

    // A plain open would wait here for a writer that never comes, so this call is the check.
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);
}

test "a folder file that is a symlink is a bad record, even when the link leads to a valid folder path" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    // The target holds a folder path that would be accepted, so only the no-follow open refuses the link.
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = root });
    const target_path = try alloc.print("{s}/target", .{root});
    defer alloc.free(target_path);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    try folder.symLink(io, target_path, folder_file, .{});

    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try std.testing.expect(session.startFolder() == null);
}

test "a save-status that is a FIFO is replaced by an empty owner-only file, and the next program saves its state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.deleteFile(io, save_status_file);
    const status_path = try alloc.print("{s}/{s}", .{ dir, save_status_file });
    defer alloc.free(status_path);
    try makeFifo(alloc, io, status_path);

    // Reported once as a failure, and then an empty owner-only regular file.
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
    const stat = try folder.statFile(io, save_status_file, .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u64, 0), stat.size);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    // The next program's `pending` write and its save both go through, and its state carries.
    const first = try runProgram(alloc, io, &session, dir, "fifo1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    const second = try runProgram(alloc, io, &session, dir, "fifo2", "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a save-status that is a link is replaced by an empty owner-only file, and the file it names is not written" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere", .data = "keep\n" });
    const target = try alloc.print("{s}/elsewhere", .{root});
    defer alloc.free(target);
    try folder.deleteFile(io, save_status_file);
    try folder.symLink(io, target, save_status_file, .{});

    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
    const stat = try folder.statFile(io, save_status_file, .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    const kept = try tmp.dir.readFileAlloc(io, "elsewhere", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
}

test "a folder file that is a FIFO is bad once, and then there is no folder file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const folder_path = try alloc.print("{s}/{s}", .{ dir, folder_file });
    defer alloc.free(folder_path);
    try makeFifo(alloc, io, folder_path);

    // The first refresh reports the FIFO and unlinks it; the next one finds no folder file.
    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try std.testing.expectEqual(StartFolderStatus.no_record, session.refreshStartFolder(io));
    try std.testing.expectError(error.FileNotFound, folder.statFile(io, folder_file, .{}));
    try std.testing.expect(session.startFolder() == null);
}

test "a startup record that is a FIFO or a link is replaced, and a regular one is left alone" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);

    // A regular record is left alone: nothing is repaired.
    const quiet = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 0), quiet.items().len);

    // A FIFO where the functions record is: replaced, once.
    try folder.deleteFile(io, startup_functions_file);
    const functions_path = try alloc.print("{s}/{s}", .{ dir, startup_functions_file });
    defer alloc.free(functions_path);
    try makeFifo(alloc, io, functions_path);
    const replaced = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), replaced.items().len);
    try std.testing.expectEqual(RepairKind.record_replaced, replaced.items()[0].what);
    try std.testing.expectEqualStrings(startup_functions_file, replaced.items()[0].name);
    const functions = try folder.statFile(io, startup_functions_file, .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, functions.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), functions.permissions.toMode() & 0o777);
    const again = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 0), again.items().len);

    // A link where the aliases record is: unlinked, and its target is not written.
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere", .data = "keep\n" });
    const target = try alloc.print("{s}/elsewhere", .{root});
    defer alloc.free(target);
    try folder.deleteFile(io, startup_aliases_file);
    try folder.symLink(io, target, startup_aliases_file, .{});
    const linked = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), linked.items().len);
    try std.testing.expectEqualStrings(startup_aliases_file, linked.items()[0].name);
    const aliases = try folder.statFile(io, startup_aliases_file, .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, aliases.kind);
    const kept = try tmp.dir.readFileAlloc(io, "elsewhere", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
}

test "heal makes a session folder that a program removed again, and the state it held is lost" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const old_dir = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(old_dir);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    // A program removes its session folder, as in review r30.
    try std.Io.Dir.cwd().deleteTree(io, old_dir);
    try std.testing.expectEqual(StartFolderStatus.no_record, session.refreshStartFolder(io));
    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), healed.items().len);
    try std.testing.expectEqual(RepairKind.state_lost, healed.items()[0].what);
    try std.testing.expect(!std.mem.eql(u8, old_dir, session.dir.?));

    // The next program starts with no state, in the new folder.
    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=${x-unset}\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=unset\n", next.stdout);
}

test "heal removes a state file that is not a regular file, and the state is lost" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    // A FIFO where the saved state was, as a program can leave it. The next program's shell would wait on it.
    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.deleteFile(io, state_file);
    const state_path = try alloc.print("{s}/{s}", .{ dir, state_file });
    defer alloc.free(state_path);
    try makeFifo(alloc, io, state_path);

    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), healed.items().len);
    try std.testing.expectEqual(RepairKind.state_lost, healed.items()[0].what);
    try std.testing.expectEqualStrings(state_file, healed.items()[0].name);
    try std.testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(io, folder, state_file));

    // A healthy folder has nothing to repair.
    const again = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 0), again.items().len);
}

test "heal writes env.sh again when a program replaced it, and the saved state still loads" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    const dir = session.dir.?;
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.deleteFile(io, env_file);
    const env_path = try alloc.print("{s}/{s}", .{ dir, env_file });
    defer alloc.free(env_path);
    try makeFifo(alloc, io, env_path);

    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), healed.items().len);
    try std.testing.expectEqual(RepairKind.env_rewritten, healed.items()[0].what);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try folder.statFile(io, env_file, .{ .follow_symlinks = false })).kind);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "heal replaces a directory at the folder file, the save record, or a startup record, and leaves a FIFO at the save record for takeSaveStatus" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    // A directory with a file inside it where each of three records is, as a stray program can leave one.
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    for ([_][]const u8{ folder_file, save_status_file, startup_aliases_file }) |name| {
        try folder.deleteFile(io, name);
        try folder.createDirPath(io, name);
        var inside = try folder.openDir(io, name, .{});
        defer inside.close(io);
        try inside.writeFile(io, .{ .sub_path = "inside", .data = "keep\n" });
    }

    const healed = session.heal(io, &test_fx_variables);
    const items = healed.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings(folder_file, items[0].name);
    try std.testing.expectEqualStrings(save_status_file, items[1].name);
    try std.testing.expectEqualStrings(startup_aliases_file, items[2].name);
    for (items) |repair| try std.testing.expectEqual(RepairKind.record_replaced, repair.what);

    // The folder file is gone, and the start folder it named is reported once.
    try std.testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(io, folder, folder_file));
    try std.testing.expect(session.takeFolderDropped());
    try std.testing.expect(!session.takeFolderDropped());

    // The save record and the startup record are empty owner-only regular files again.
    for ([_][]const u8{ save_status_file, startup_aliases_file }) |name| {
        const stat = try folder.statFile(io, name, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    const again = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 0), again.items().len);

    // A FIFO at the save record is left for takeSaveStatus, which reports it as a failed record.
    try folder.deleteFile(io, save_status_file);
    const status_path = try alloc.print("{s}/{s}", .{ session.dir.?, save_status_file });
    defer alloc.free(status_path);
    try makeFifo(alloc, io, status_path);
    const fifo = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 0), fifo.items().len);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }

    // The saved state is still there for the next program.
    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a write whose temporary entry is a link to a file outside the folder is refused, and that file is unchanged" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);

    // A file outside the session folder, and a link inside the folder at the temporary name, pointing at it.
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    try folder.symLink(io, outside, "planted.tmp", .{});

    // The exclusive create refuses the existing link, so the file it names is never opened.
    try std.testing.expectError(error.PathAlreadyExists, writeViaTemp(io, folder, env_file, "EVIL\n", "planted.tmp"));
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
    // env.sh is the one prepare wrote, and the refused write left it alone.
    const env_bytes = try folder.readFileAlloc(io, env_file, alloc, .limited(1 << 20));
    defer alloc.free(env_bytes);
    try std.testing.expect(std.mem.find(u8, env_bytes, "EVIL") == null);
}

test "a link at the old env.sh.tmp name, pointing at a file outside the folder, is not written through: heal writes a fresh env.sh" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    try folder.deleteFile(io, env_file);
    try folder.symLink(io, outside, "env.sh.tmp", .{});

    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), healed.items().len);
    try std.testing.expectEqual(RepairKind.env_rewritten, healed.items()[0].what);
    try std.testing.expect(healed.repair_failed == null);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try entryKind(io, folder, env_file)).?);
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
    // The old name is not used, so the link there is left as it is.
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(io, folder, "env.sh.tmp")).?);

    const next = try runProgram(alloc, io, &session, root, "t1", "echo ok");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("ok\n", next.stdout);
}

test "a directory and then a FIFO at env.sh are replaced by a fresh env.sh before the next program, which keeps its state" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const env_path = try alloc.print("{s}/{s}", .{ session.dir.?, env_file });
    defer alloc.free(env_path);

    // A directory with a file in it where env.sh is.
    try folder.deleteFile(io, env_file);
    try folder.createDirPath(io, env_file);
    try folder.writeFile(io, .{ .sub_path = "env.sh/inside", .data = "keep\n" });
    const first = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), first.items().len);
    try std.testing.expectEqual(RepairKind.env_rewritten, first.items()[0].what);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try entryKind(io, folder, env_file)).?);
    const kept = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, kept);
    try expectExit(kept, 0);
    try std.testing.expectEqualStrings("x=1\n", kept.stdout);

    // A FIFO where env.sh is.
    try folder.deleteFile(io, env_file);
    try makeFifo(alloc, io, env_path);
    const second = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), second.items().len);
    try std.testing.expectEqual(RepairKind.env_rewritten, second.items()[0].what);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try entryKind(io, folder, env_file)).?);
    const again = try runProgram(alloc, io, &session, root, "t3", "echo \"x=$x\"");
    defer freeRun(alloc, again);
    try expectExit(again, 0);
    try std.testing.expectEqualStrings("x=1\n", again.stdout);
}

test "a FIFO at the old env.sh.tmp name does not block the repair of a missing env.sh" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    try folder.deleteFile(io, env_file);
    const old_name = try alloc.print("{s}/env.sh.tmp", .{session.dir.?});
    defer alloc.free(old_name);
    try makeFifo(alloc, io, old_name);

    // A plain write to the old name would wait here for a reader that never comes, so this call is the check.
    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expectEqual(@as(usize, 1), healed.items().len);
    try std.testing.expect(healed.repair_failed == null);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try entryKind(io, folder, env_file)).?);
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, (try entryKind(io, folder, "env.sh.tmp")).?);

    const next = try runProgram(alloc, io, &session, root, "t1", "echo ok");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("ok\n", next.stdout);
}

test "a repair that cannot complete starts a fresh session, which keeps the state the next program saves" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const saved = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    const old_dir = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(old_dir);

    // env.sh is removed, and the folder is read-only, so the repair cannot write env.sh.
    // Opened for iteration, so the handle is a real descriptor that setPermissions can change.
    var old = try std.Io.Dir.cwd().openDir(io, old_dir, .{ .iterate = true });
    defer old.close(io);
    try old.deleteFile(io, env_file);
    try old.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    defer old.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the mode is restored only so the temporary directory can be removed.
    // Root or a DAC-override user writes into the read-only folder, so the repair would not fail: skip.
    if (modeIgnored(io, old)) return error.SkipZigTest;

    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expect(healed.repair_failed != null);
    try std.testing.expect(healed.fresh_failed == null);
    try std.testing.expect(healed.stateLost());
    try std.testing.expect(!std.mem.eql(u8, old_dir, session.dir.?));

    // The next program runs in the fresh session, with no state, and the one after keeps the state it saves.
    const fresh = try runProgram(alloc, io, &session, root, "t2", "echo \"x=${x-unset}\"");
    defer freeRun(alloc, fresh);
    try expectExit(fresh, 0);
    try std.testing.expectEqualStrings("x=unset\n", fresh.stdout);
    const saved_again = try runProgram(alloc, io, &session, root, "t3", "x=3");
    defer freeRun(alloc, saved_again);
    try expectExit(saved_again, 0);
    const kept = try runProgram(alloc, io, &session, root, "t4", "echo \"x=$x\"");
    defer freeRun(alloc, kept);
    try expectExit(kept, 0);
    try std.testing.expectEqualStrings("x=3\n", kept.stdout);
}

test "a refresh that drops the start folder sets the flag, which is read once" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    const folder_path = try alloc.print("{s}/{s}", .{ dir, folder_file });
    defer alloc.free(folder_path);
    try makeFifo(alloc, io, folder_path);

    try std.testing.expectEqual(StartFolderStatus.bad_record, session.refreshStartFolder(io));
    try std.testing.expect(session.takeFolderDropped());
    try std.testing.expect(!session.takeFolderDropped());

    // With no folder file, a refresh drops nothing.
    try std.testing.expectEqual(StartFolderStatus.no_record, session.refreshStartFolder(io));
    try std.testing.expect(!session.takeFolderDropped());
}

test "a program that puts a FIFO where its save record is still saves its state, and the record gives no notice" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    // The program replaces its own save record with a FIFO, then sets x. Its save must not wait on the FIFO.
    const replaced = try runProgram(alloc, io, &session, root, "t1", "rm -f -- \"$__fx_status\"; /usr/bin/mkfifo \"$__fx_status\"; x=1");
    defer freeRun(alloc, replaced);
    try expectExit(replaced, 0);
    try std.testing.expectEqualStrings("", replaced.stdout);

    // The save kept the state, so the record is again an empty owner-only regular file, and it says nothing.
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const record = try folder.statFile(io, save_status_file, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, record.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), record.permissions.toMode() & 0o777);
    const status = session.takeSaveStatus(io);
    try std.testing.expect(status == null);

    // The next program sees x=1.
    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a program that puts a link at its save record to a directory saves its state, and the directory is left whole" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    // A directory with a file in it, outside the session folder, which the link names.
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/keep", .data = "keep\n" });
    const target = try alloc.print("{s}/target", .{root});
    defer alloc.free(target);
    const program = try alloc.print("rm -f -- \"$__fx_status\"; ln -s '{s}' \"$__fx_status\"; x=1", .{target});
    defer alloc.free(program);
    const saved = try runProgram(alloc, io, &session, root, "t1", program);
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    // The record is an empty owner-only regular file, and the directory the link named is whole.
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const record = try folder.statFile(io, save_status_file, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, record.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), record.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u64, 0), record.size);
    const kept = try tmp.dir.readFileAlloc(io, "target/keep", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
    try std.testing.expect(session.takeSaveStatus(io) == null);
}

test "a program that plants a FIFO at the save's state temp name is not blocked: the next program sees its state, and no notice is given" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    // The save writes `<state>.<pid>.tmp` with the pid of the program's own shell, so the FIFO is at the name it opens.
    const saved = try runProgram(alloc, io, &session, root, "t1", "/usr/bin/mkfifo \"$__fx_state.$$.tmp\"; x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    try std.testing.expectEqualStrings("", saved.stdout);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a program that plants a link at the save's folder temp name, pointing outside the folder, leaves that file unchanged and saves its start folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    // A file outside the session folder, which the link names, and the directory the program moves to.
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    try tmp.dir.createDirPath(io, "sub");
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    const sub = try alloc.print("{s}/sub", .{root});
    defer alloc.free(sub);
    const program = try alloc.print("ln -s '{s}' \"$__fx_folder.$$.tmp\"; cd '{s}'; x=1", .{ outside, sub });
    defer alloc.free(program);
    const saved = try runProgram(alloc, io, &session, root, "t1", program);
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);

    // The link is replaced, so the write never reaches the file it names.
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);

    // The save wrote the program's folder into the folder file, and no notice is given.
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const start = try folder.readFileAlloc(io, folder_file, alloc, .limited(4096));
    defer alloc.free(start);
    try std.testing.expectEqualStrings(sub, start);
    try std.testing.expect(session.takeSaveStatus(io) == null);
}

test "a program that plants FIFOs at the save's functions and aliases temp names is not blocked, and its state carries" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    const saved = try runProgram(alloc, io, &session, root, "t1", "/usr/bin/mkfifo \"$__fx_state.$$.functions\"; /usr/bin/mkfifo \"$__fx_state.$$.aliases\"; x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    try std.testing.expectEqualStrings("", saved.stdout);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a program that leaves a directory at its state file saves its state over it, prints nothing, and the next program sees its state" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    // The save moves its temporary file over the state file, so the directory must go first.
    const saved = try runProgram(alloc, io, &session, root, "t1", "rm -f -- \"$__fx_state\"; mkdir -p \"$__fx_state/inner\"; x=1");
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    try std.testing.expectEqualStrings("", saved.stdout);
    try std.testing.expectEqualStrings("", saved.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const state = try folder.statFile(io, "state.sh", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, state.kind);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a program that leaves a directory at its start folder file saves its start folder over it, and prints nothing" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    try tmp.dir.createDirPath(io, "sub");
    const sub = try alloc.print("{s}/sub", .{root});
    defer alloc.free(sub);
    const program = try alloc.print("rm -f -- \"$__fx_folder\"; mkdir -p \"$__fx_folder/inner\"; cd '{s}'; x=1", .{sub});
    defer alloc.free(program);
    const saved = try runProgram(alloc, io, &session, root, "t1", program);
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    try std.testing.expectEqualStrings("", saved.stdout);
    try std.testing.expectEqualStrings("", saved.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    const start = try folder.readFileAlloc(io, folder_file, alloc, .limited(4096));
    defer alloc.free(start);
    try std.testing.expectEqualStrings(sub, start);
}

test "a program that leaves a link at its state file, pointing outside the folder, leaves that file unchanged and saves its state" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);

    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    const program = try alloc.print("rm -f -- \"$__fx_state\"; ln -s '{s}' \"$__fx_state\"; x=1", .{outside});
    defer alloc.free(program);
    const saved = try runProgram(alloc, io, &session, root, "t1", program);
    defer freeRun(alloc, saved);
    try expectExit(saved, 0);
    try std.testing.expectEqualStrings("", saved.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a publish that cannot clear the start folder is recorded as failed, and the state it did not change carries" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    // A read-only folder stops the removal of what it holds. A user with a DAC-override capability, or root,
    // still removes it, so the test skips for that user, as the permission tests do.
    try tmp.dir.createDirPath(io, "probe");
    var probe = try tmp.dir.openDir(io, "probe", .{ .iterate = true });
    defer probe.close(io);
    try probe.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    defer probe.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the probe is restored so the temporary directory can be removed.
    if (modeIgnored(io, probe)) return error.SkipZigTest;

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    var session_folder = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer session_folder.close(io);

    const first = try runProgram(alloc, io, &session, dir, "first", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    // The program replaces the start folder file with a directory that holds a file, and makes that directory
    // read-only. The save cannot remove it, so it publishes nothing and records the failure.
    const second = try runProgram(alloc, io, &session, dir, "blocked", "rm -f -- \"$__fx_folder\"; mkdir -p \"$__fx_folder/inner\"; /bin/chmod 500 \"$__fx_folder\"; x=2");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("", second.stderr);
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .over_cap => return error.TestUnexpectedOverCap,
        .failed => {},
        .not_saved => return error.TestUnexpectedStatus,
    }

    // Restores the folder so the directory can be removed, then checks that the state the save did not change carries.
    var blocked = try session_folder.openDir(io, folder_file, .{ .iterate = true });
    defer blocked.close(io);
    try blocked.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));

    const third = try runProgram(alloc, io, &session, dir, "after-blocked", "echo \"x=$x\"");
    defer freeRun(alloc, third);
    try expectExit(third, 0);
    try std.testing.expectEqualStrings("x=1\n", third.stdout);
}

test "a link to an outside file at the save record is replaced, and the outside file is not written" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    const record = try alloc.print("{s}/{s}", .{ dir, save_status_file });
    defer alloc.free(record);
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.deleteFile(io, save_status_file);
    try makeHardLink(alloc, io, outside, record);

    // The record is not a regular file of its own, so it reads as failed, and the outside file keeps its bytes.
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);

    // The record is now an empty owner-only file with no other name.
    const replaced = try folder.statFile(io, save_status_file, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, replaced.kind);
    try std.testing.expectEqual(@as(std.posix.nlink_t, 1), replaced.nlink);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), replaced.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u64, 0), replaced.size);
}

test "a link to an outside file at a startup record is replaced before the next load, which does not write the outside file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    const record = try alloc.print("{s}/{s}", .{ dir, startup_functions_file });
    defer alloc.free(record);
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.deleteFile(io, startup_functions_file);
    try makeHardLink(alloc, io, outside, record);

    // The call's heal runs before the program's load, as in every call.
    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expect(healed.repair_failed == null);
    try std.testing.expect(healedHas(&healed, .record_replaced, startup_functions_file));

    const first = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);

    const next = try runProgram(alloc, io, &session, root, "t2", "echo \"x=$x\"");
    defer freeRun(alloc, next);
    try expectExit(next, 0);
    try std.testing.expectEqualStrings("x=1\n", next.stdout);
}

test "a link to an outside file at env.sh or state.sh is replaced by heal, and the outside file is not written" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;
    const first = try runProgram(alloc, io, &session, root, "t1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep\n" });
    const outside = try alloc.print("{s}/outside", .{root});
    defer alloc.free(outside);
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const env_path = try alloc.print("{s}/{s}", .{ dir, env_file });
    defer alloc.free(env_path);
    const state_path = try alloc.print("{s}/{s}", .{ dir, state_file });
    defer alloc.free(state_path);
    try folder.deleteFile(io, env_file);
    try makeHardLink(alloc, io, outside, env_path);
    try folder.deleteFile(io, state_file);
    try makeHardLink(alloc, io, outside, state_path);

    const healed = session.heal(io, &test_fx_variables);
    try std.testing.expect(healed.repair_failed == null);
    try std.testing.expect(healedHas(&healed, .env_rewritten, env_file));
    try std.testing.expect(healedHas(&healed, .state_lost, state_file));
    try std.testing.expect(session.lossPending());
    const kept = try tmp.dir.readFileAlloc(io, "outside", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
}

test "a fresh folder made because the old one could not be repaired leaves the old folder, and a later heal removes it" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const old_path = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(old_path);

    // env.sh is gone and the old folder is read-only, so its repair cannot write env.sh and its removal cannot unlink its entries.
    var old = try std.Io.Dir.cwd().openDir(io, old_path, .{ .iterate = true });
    defer old.close(io);
    defer old.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: restored so the temporary directory can be removed.
    try old.deleteFile(io, env_file);
    try old.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    // Root or a DAC-override user writes into the read-only folder, so the repair would not fail: skip.
    if (modeIgnored(io, old)) return error.SkipZigTest;

    const first = session.heal(io, &test_fx_variables);
    try std.testing.expect(first.repair_failed != null);
    try std.testing.expect(first.forget_failed != null);
    try std.testing.expect(first.fresh_failed == null);
    _ = try std.Io.Dir.cwd().statFile(io, old_path, .{ .follow_symlinks = false });

    // A later heal retries the removal, which now reaches the old folder, and the new folder is healthy.
    const second = session.heal(io, &test_fx_variables);
    try std.testing.expect(second.repair_failed == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, old_path, .{ .follow_symlinks = false }));
}

test "deinit removes an old folder that a later removal reaches, and reports none left" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const old_path = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(old_path);

    var old = try std.Io.Dir.cwd().openDir(io, old_path, .{ .iterate = true });
    defer old.close(io);
    defer old.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: restored so the temporary directory can be removed.
    try old.deleteFile(io, env_file);
    try old.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    if (modeIgnored(io, old)) return error.SkipZigTest;

    const first = session.heal(io, &test_fx_variables);
    try std.testing.expect(first.forget_failed != null);
    try std.testing.expectEqual(@as(usize, 0), session.deinit(io));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, old_path, .{ .follow_symlinks = false }));
}

test "deinit reports an old folder that a child keeps, and leaves it on disk" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const old_path = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(old_path);

    // A read-only child that holds a file cannot be emptied, so the old folder's removal stays,
    // whatever the old folder's own mode is.
    var old = try std.Io.Dir.cwd().openDir(io, old_path, .{ .iterate = true });
    defer old.close(io);
    defer old.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: restored so the temporary directory can be removed.
    try old.createDirPath(io, "kept");
    try old.writeFile(io, .{ .sub_path = "kept/f", .data = "" });
    var kept = try old.openDir(io, "kept", .{ .iterate = true });
    defer kept.close(io);
    defer kept.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: restored so the temporary directory can be removed.
    try kept.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    if (modeIgnored(io, kept)) return error.SkipZigTest;
    try old.deleteFile(io, env_file);
    try old.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));

    const first = session.heal(io, &test_fx_variables);
    try std.testing.expect(first.forget_failed != null);
    try std.testing.expectEqual(@as(usize, 1), session.deinit(io));
    _ = try std.Io.Dir.cwd().statFile(io, old_path, .{ .follow_symlinks = false });
}

test "a save record too long to read is reported once, and then emptied" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);

    const oversized: [max_status_bytes + 1]u8 = @splat('x');
    try folder.writeFile(io, .{ .sub_path = save_status_file, .data = &oversized });
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
    // The record was emptied though it could not be read, so the next take reports nothing again.
    try std.testing.expect(session.takeSaveStatus(io) == null);
}

test "a save-status that is a FIFO is a failed record, and the call returns" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    try folder.deleteFile(io, save_status_file);
    const status_path = try alloc.print("{s}/{s}", .{ session.dir.?, save_status_file });
    defer alloc.free(status_path);
    try makeFifo(alloc, io, status_path);

    // A plain open would wait here for a writer that never comes, so this call is the check.
    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
}

test "a save-status that is a symlink is a failed record, and the file it names is not truncated" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "cap 42\n" });
    const target_path = try alloc.print("{s}/target", .{root});
    defer alloc.free(target_path);
    var folder = try std.Io.Dir.cwd().openDir(io, session.dir.?, .{});
    defer folder.close(io);
    try folder.deleteFile(io, save_status_file);
    try folder.symLink(io, target_path, save_status_file, .{});

    switch (session.takeSaveStatus(io) orelse return error.TestNoSaveStatus) {
        .failed => {},
        .over_cap, .not_saved => return error.TestUnexpectedStatus,
    }
    const kept = try tmp.dir.readFileAlloc(io, "target", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("cap 42\n", kept);
}

test "a program that hides awk and mv from PATH still saves its state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "path1", "PATH=/nonexistent; x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const second = try runProgram(alloc, io, &session, dir, "path2", "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a startup that sets noclobber writes its records and saves no startup function" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgramAfterStartup(alloc, io, &session, dir, "clobber1", "set -C; f() { echo SF; }", &.{}, "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);

    // The next startup defines f differently, so the program's f is the next startup's only if
    // the first startup's f was not saved.
    const second = try runProgramAfterStartup(alloc, io, &session, dir, "clobber2", "set -C; f() { echo SF2; }", &.{}, "echo \"x=$x $(f)\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1 SF2\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);
}

test "a startup that sets IFS to letters does not stop the save" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgramAfterStartup(alloc, io, &session, dir, "letters1", "IFS=abc", &.{}, "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expect(session.takeSaveStatus(io) == null);

    const second = try runProgramAfterStartup(alloc, io, &session, dir, "letters2", "IFS=abc", &.{}, "echo \"x=$x\"");
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("x=1\n", second.stdout);
}

test "a program that ends after its folder is gone saves nothing and prints nothing" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const program = try alloc.print("rm -rf -- '{s}'; x=2", .{dir});
    defer alloc.free(program);
    const run = try runProgram(alloc, io, &session, root, "gone", program);
    defer freeRun(alloc, run);
    try expectExit(run, 0);
    try std.testing.expectEqualStrings("", run.stderr);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));
}

test "variables fx adds to every program are not restored in the next one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer _ = session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const set = try runProgram(alloc, io, &session, dir, "fx1", "export AI_AGENT=fx FX_MCP_CALL_SOCKET=/tmp/sock FX_KEEP=yes");
    defer freeRun(alloc, set);
    try expectExit(set, 0);

    const read = try runProgram(alloc, io, &session, dir, "fx2", "echo \"agent=${AI_AGENT:-unset} sock=${FX_MCP_CALL_SOCKET:-unset} keep=${FX_KEEP:-unset}\"");
    defer freeRun(alloc, read);
    try expectExit(read, 0);
    try std.testing.expectEqualStrings("agent=unset sock=unset keep=yes\n", read.stdout);
}

test "prepare refuses a variable name that is not a plain word" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    for ([_][]const u8{ "", "BAD NAME", "A|B", "A-B" }) |name| {
        var session = Session.init(alloc);
        defer _ = session.deinit(io);
        try std.testing.expectError(error.InvalidVariableName, session.prepare(io, root, &.{name}));
        try std.testing.expect(session.dir == null);
    }
    var entries = tmp.dir.iterate();
    try std.testing.expect((try entries.next(io)) == null);
}
