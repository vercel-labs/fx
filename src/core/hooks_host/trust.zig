//! Which hooks a person trusted, kept in `~/.fx/hooks-trust.json`, and the
//! digest that names what was trusted: the hook and the files it runs.

const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const trust_file_name = "hooks-trust.json";
const max_file_bytes = 1024 * 1024;
pub const max_entries = 4096;
/// How many temp names `save` tries before it gives up.
const temp_attempts = 8;
/// The mode of the trust file, its temp file, its lock file, and the run log: only the owner
/// reads or writes them.
pub const private_file_mode = 0o600;
/// The mode bits that let the group or others write a file. A trust file that has any of them
/// is refused, and a profile hook file that has any of them is ignored, because someone else
/// could change what runs or what is trusted.
pub const group_or_other_write = 0o022;
const max_content_bytes = 64 * 1024 * 1024;
const content_chunk = 64 * 1024;

const Sha256 = std.crypto.hash.sha2.Sha256;
/// A digest as hex text: two characters for each byte.
const hex_length = 2 * Sha256.digest_length;

/// `~/.fx/hooks-trust.json`, or under `$FX_HOME`. The caller owns the result.
pub fn path(alloc: std.mem.Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{trust_file_name});
}

/// One trusted hook. `label` says what it was, for `fx hook list`.
pub const Entry = struct { digest: [hex_length]u8, label: []u8 };

/// One hook the person disabled for one workspace. Both strings are owned.
pub const Disabled = struct { workspace: []u8, id: []u8 };

/// The trusted digests and the hooks the person disabled. Owns its memory; free it with deinit.
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// One entry per workspace and hook id.
    disabled: std.ArrayList(Disabled) = .empty,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| alloc.free(entry.label);
        self.entries.deinit(alloc);
        for (self.disabled.items) |item| {
            alloc.free(item.workspace);
            alloc.free(item.id);
        }
        self.disabled.deinit(alloc);
        self.* = undefined;
    }

    pub fn contains(self: *const Store, value: [Sha256.digest_length]u8) bool {
        const wanted = hex(value);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.digest, &wanted)) return true;
        }
        return false;
    }

    /// Adds a digest with a copy of `label`. Does nothing when it is there.
    pub fn add(self: *Store, alloc: std.mem.Allocator, value: [Sha256.digest_length]u8, label: []const u8) std.mem.Allocator.Error!void {
        if (self.contains(value)) return;
        const text = hex(value);
        const copy = try alloc.dupe(u8, label);
        errdefer alloc.free(copy);
        try self.entries.append(alloc, .{ .digest = text, .label = copy });
    }

    /// Whether the person disabled hook `id` for `workspace_root`.
    pub fn isDisabled(self: *const Store, workspace_root: []const u8, id: []const u8) bool {
        return self.disabledIndex(workspace_root, id) != null;
    }

    /// Records or clears that the person disabled hook `id` for `workspace_root`. Recording it again keeps
    /// one entry, and clearing a hook that is not disabled does nothing.
    pub fn setDisabled(self: *Store, alloc: std.mem.Allocator, workspace_root: []const u8, id: []const u8, disabled: bool) std.mem.Allocator.Error!void {
        if (self.disabledIndex(workspace_root, id)) |index| {
            if (disabled) return;
            const removed = self.disabled.orderedRemove(index);
            alloc.free(removed.workspace);
            alloc.free(removed.id);
            return;
        }
        if (!disabled) return;
        const workspace = try alloc.dupe(u8, workspace_root);
        errdefer alloc.free(workspace);
        const hook_id = try alloc.dupe(u8, id);
        errdefer alloc.free(hook_id);
        try self.disabled.append(alloc, .{ .workspace = workspace, .id = hook_id });
    }

    fn disabledIndex(self: *const Store, workspace_root: []const u8, id: []const u8) ?usize {
        for (self.disabled.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.workspace, workspace_root) and std.mem.eql(u8, item.id, id)) return index;
        }
        return null;
    }
};

pub const LoadError = std.mem.Allocator.Error || error{ TrustFileUnsafe, TrustFileInvalid, TrustFileUnreadable };

/// Reads the trust file. A missing file is an empty store. A file that group or
/// others can write is refused (TrustFileUnsafe), so another account cannot add trust.
pub fn load(alloc: std.mem.Allocator, file_path: []const u8) LoadError!Store {
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Store{},
        else => return error.TrustFileUnreadable,
    };
    defer file.close(io);

    const stat = file.stat(io) catch return error.TrustFileUnreadable;
    if (stat.kind != .file or stat.permissions.toMode() & group_or_other_write != 0) {
        debug_trace.logf("hooks", "refused to read {s}: group or others can write it, or it is not a file", .{file_path});
        return error.TrustFileUnsafe;
    }
    if (stat.size > max_file_bytes) return error.TrustFileInvalid;

    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes + 1) catch return error.TrustFileUnreadable;
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TrustFileInvalid,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.TrustFileInvalid;
    const version = parsed.value.object.get("version") orelse return error.TrustFileInvalid;
    if (version != .integer or version.integer != 1) return error.TrustFileInvalid;
    const trusted = parsed.value.object.get("trusted") orelse return error.TrustFileInvalid;
    if (trusted != .array) return error.TrustFileInvalid;
    if (trusted.array.items.len > max_entries) return error.TrustFileInvalid;

    var store = Store{};
    errdefer store.deinit(alloc);
    for (trusted.array.items) |item| {
        if (item != .object) return error.TrustFileInvalid;
        const digest_value = item.object.get("digest") orelse return error.TrustFileInvalid;
        if (digest_value != .string) return error.TrustFileInvalid;
        var digest_bytes: [Sha256.digest_length]u8 = undefined;
        if (!parseHex(digest_value.string, &digest_bytes)) return error.TrustFileInvalid;
        const label_value = item.object.get("label") orelse return error.TrustFileInvalid;
        if (label_value != .string) return error.TrustFileInvalid;
        try store.add(alloc, digest_bytes, label_value.string);
    }
    // A file from before disabled hooks has no such list, so it loads with none.
    if (parsed.value.object.get("disabled")) |disabled_value| {
        if (disabled_value != .array) return error.TrustFileInvalid;
        for (disabled_value.array.items) |item| {
            if (item != .object) return error.TrustFileInvalid;
            const workspace_value = item.object.get("workspace") orelse return error.TrustFileInvalid;
            if (workspace_value != .string) return error.TrustFileInvalid;
            const id_value = item.object.get("id") orelse return error.TrustFileInvalid;
            if (id_value != .string) return error.TrustFileInvalid;
            try store.setDisabled(alloc, workspace_value.string, id_value.string, true);
        }
    }
    return store;
}

/// A held write lock on a trust file or a run log, from `lockWriters`. `release` ends it.
pub const WriteLock = struct {
    file: std.Io.File,

    pub fn release(self: WriteLock) void {
        self.file.close(io_mod.getIo());
    }
};

/// How long `lockWriters` waits between two tries for the lock.
const lock_retry_ms = 10;

/// Takes the exclusive lock that every writer of `file_path` holds from its read or
/// check through its rewrite, so two fx processes never lose each other's change or
/// rotate a log at once. The lock is the sibling `<file_path>.lock`, which is never
/// renamed. Readers take no lock, because a rename replaces the whole file.
///
/// It tries without blocking every `lock_retry_ms`, for up to `wait_ms`. When the lock is
/// still held then, it returns `error.TrustFileBusy`, so no caller waits on another
/// process for longer than it chose. A `wait_ms` of 0 makes exactly one try and no sleep:
/// the first failed try is already at the deadline.
pub fn lockWriters(alloc: std.mem.Allocator, file_path: []const u8, wait_ms: u32) !WriteLock {
    const io = io_mod.getIo();
    if (std.Io.Dir.path.dirname(file_path)) |folder| {
        try std.Io.Dir.cwd().createDirPath(io, folder);
    }
    const lock_path = try alloc.print("{s}.lock", .{file_path});
    defer alloc.free(lock_path);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + @as(i64, wait_ms);
    while (true) {
        if (std.Io.Dir.createFileAbsolute(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = std.Io.File.Permissions.fromMode(private_file_mode),
        })) |file| {
            return .{ .file = file };
        } else |err| {
            if (err != error.WouldBlock) return err;
        }
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TrustFileBusy;
        io_mod.sleep(lock_retry_ms * std.time.ns_per_ms);
    }
}

/// The temp file `save` writes first: the first `<file_path>.tmp.N` that does not exist
/// yet. Each name is created exclusively, so a file or link planted at a name is skipped,
/// never written through.
const Temp = struct { name: []u8, file: std.Io.File };

fn createTemp(alloc: std.mem.Allocator, io: std.Io, file_path: []const u8) !Temp {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const name = try alloc.print("{s}.tmp.{d}", .{ file_path, attempt });
        if (std.Io.Dir.createFileAbsolute(io, name, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(private_file_mode),
        })) |file| {
            return .{ .name = name, .file = file };
        } else |err| {
            alloc.free(name);
            if (err != error.PathAlreadyExists or attempt + 1 == temp_attempts) return err;
        }
    }
}

/// Writes the store to a temp file with mode 0600 in the same folder, syncs it,
/// and renames it over `file_path`. The caller holds `lockWriters` for `file_path`.
pub fn save(alloc: std.mem.Allocator, file_path: []const u8, store: *const Store) !void {
    const io = io_mod.getIo();

    if (std.Io.Dir.path.dirname(file_path)) |folder| {
        try std.Io.Dir.cwd().createDirPath(io, folder);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    writeStore(&json, store) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    const text = try out.toOwnedSlice();
    defer alloc.free(text);

    const temp = try createTemp(alloc, io, file_path);
    defer alloc.free(temp.name);

    var cleanup = true;
    // Runs only when the rename did not. A temp file that a failed delete leaves behind is skipped by the next createTemp.
    defer if (cleanup) std.Io.Dir.deleteFileAbsolute(io, temp.name) catch {};

    {
        var file = temp.file;
        defer file.close(io);
        try file.writeStreamingAll(io, text);
        try file.sync(io);
    }

    try std.Io.Dir.renameAbsolute(temp.name, file_path, io);
    cleanup = false;
}

fn writeStore(json: *std.json.Stringify, store: *const Store) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("version");
    try json.write(@as(i64, 1));
    try json.objectField("trusted");
    try json.beginArray();
    for (store.entries.items) |entry| {
        try json.beginObject();
        try json.objectField("digest");
        try json.write(&entry.digest);
        try json.objectField("label");
        try json.write(entry.label);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("disabled");
    try json.beginArray();
    for (store.disabled.items) |item| {
        try json.beginObject();
        try json.objectField("workspace");
        try json.write(item.workspace);
        try json.objectField("id");
        try json.write(item.id);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn parseHex(text: []const u8, out: *[Sha256.digest_length]u8) bool {
    if (text.len != hex_length) return false;
    var index: usize = 0;
    while (index < Sha256.digest_length) : (index += 1) {
        const high = hexDigit(text[index * 2]) orelse return false;
        const low = hexDigit(text[index * 2 + 1]) orelse return false;
        out[index] = (high << 4) | low;
    }
    return true;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The files a hook's command names. Owns its memory.
pub const Named = struct {
    /// Resolved, sorted, without duplicates, at most `max_named_files`.
    files: [][]u8,
    /// How many more files the command named past the cap; trust does not cover them.
    dropped: usize,

    pub fn deinit(self: *Named, alloc: std.mem.Allocator) void {
        for (self.files) |file_path| alloc.free(file_path);
        if (self.files.len > 0) alloc.free(self.files);
        self.* = undefined;
    }
};

pub const max_named_files = 64;

/// The files a hook's command names, resolved and sorted. The caller owns them.
/// A word that is only the target of an output redirect (`>`, `>>`, `2>`, `&>`, `>|`, `>&`) is not
/// named: the command writes that file and does not run it. An input redirect target is named, since
/// `sh < script.sh` runs the file. A file that the command also names outside a redirect target is
/// named, through that other word.
pub fn namedFiles(
    alloc: std.mem.Allocator,
    command: hooks.config.Command,
    workspace_root: []const u8,
    home: ?[]const u8,
) std.mem.Allocator.Error!Named {
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |text| alloc.free(text);
        owned.deinit(alloc);
    }
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(alloc);
    // Parallel to `words`: true for the word that only receives the command's output.
    var redirect_targets: std.ArrayList(bool) = .empty;
    defer redirect_targets.deinit(alloc);

    switch (command) {
        .shell => |text| try splitShellWords(alloc, &words, &redirect_targets, &owned, text),
        .argv => |items| {
            // An exec-form item is one word as written; it is never split.
            for (items) |item| {
                try words.append(alloc, item);
                try redirect_targets.append(alloc, false);
            }
        },
    }

    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |candidate| alloc.free(candidate);
        candidates.deinit(alloc);
    }

    for (words.items, redirect_targets.items) |raw, is_redirect_target| {
        // The command writes this file and runs none of it, so it is not a file the hook runs.
        if (is_redirect_target) continue;
        const maybe = try substitute(alloc, raw, workspace_root, home);
        const word = maybe orelse continue;
        if (std.mem.findScalar(u8, word, '/') == null) {
            alloc.free(word);
            continue;
        }
        const absolute = std.Io.Dir.path.isAbsolute(word);
        if (absolute) {
            try appendOwned(alloc, &candidates, word);
        } else {
            const joined = std.Io.Dir.path.join(alloc, &.{ workspace_root, word }) catch |err| {
                alloc.free(word);
                return err;
            };
            alloc.free(word);
            try appendOwned(alloc, &candidates, joined);
        }
    }

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |text| alloc.free(text);
        result.deinit(alloc);
    }
    for (candidates.items) |candidate| {
        try appendOwned(alloc, &result, try std.Io.Dir.path.resolveAlloc(alloc, &.{candidate}));
    }

    std.mem.sort([]u8, result.items, {}, lessThanPath);

    var kept: usize = 0;
    for (result.items) |item| {
        if (kept > 0 and std.mem.eql(u8, result.items[kept - 1], item)) {
            alloc.free(item);
            continue;
        }
        result.items[kept] = item;
        kept += 1;
    }
    result.shrinkRetainingCapacity(kept);

    const kept_files = @min(result.items.len, max_named_files);
    const dropped = result.items.len - kept_files;
    while (result.items.len > kept_files) {
        alloc.free(result.items[result.items.len - 1]);
        result.shrinkRetainingCapacity(result.items.len - 1);
    }

    return .{ .files = try result.toOwnedSlice(alloc), .dropped = dropped };
}

fn lessThanPath(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn appendOwned(alloc: std.mem.Allocator, list: *std.ArrayList([]u8), text: []u8) std.mem.Allocator.Error!void {
    list.append(alloc, text) catch |err| {
        alloc.free(text);
        return err;
    };
}

/// Splits a shell command into words and copies each into `owned`. `redirect_targets` gets one flag per
/// word: true for the word after an output redirect (`>`, `>>`, `2>`, `&>`, `>|`, `>&`). An input redirect
/// (`<`) and every other word leave the flag false.
fn splitShellWords(
    alloc: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
    redirect_targets: *std.ArrayList(bool),
    owned: *std.ArrayList([]u8),
    text: []const u8,
) std.mem.Allocator.Error!void {
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);
    // Set by an output redirect until the next word ends. White space keeps it, so `> file` works. Any other
    // separator clears it, so a word after `;`, `(`, or a pipe is a command word and is named.
    var output_next = false;
    var previous: u8 = 0;

    for (text) |c| {
        switch (c) {
            ' ', '\t' => try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next),
            '\n', ';', '(', ')', '`' => {
                try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next);
                output_next = false;
            },
            '>' => {
                try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next);
                output_next = true;
            },
            '<' => {
                try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next);
                output_next = false;
            },
            // `>|` and `>&` continue an output redirect. Any other `|` or `&` ends the command.
            '|', '&' => {
                if (previous != '>') {
                    try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next);
                    output_next = false;
                }
            },
            else => try current.append(alloc, c),
        }
        previous = c;
    }
    try finishShellWord(alloc, words, redirect_targets, owned, &current, &output_next);
}

/// Ends the word being read, if there is one, and records whether it is an output redirect's target.
fn finishShellWord(
    alloc: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
    redirect_targets: *std.ArrayList(bool),
    owned: *std.ArrayList([]u8),
    current: *std.ArrayList(u8),
    output_next: *bool,
) std.mem.Allocator.Error!void {
    if (current.items.len == 0) return;
    try keepWord(alloc, words, owned, current.items);
    try redirect_targets.append(alloc, output_next.*);
    output_next.* = false;
    current.clearRetainingCapacity();
}

fn keepWord(
    alloc: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
    raw: []const u8,
) std.mem.Allocator.Error!void {
    var clean: std.ArrayList(u8) = .empty;
    errdefer clean.deinit(alloc);
    for (raw) |c| {
        if (c == '\'' or c == '"') continue;
        try clean.append(alloc, c);
    }
    try appendOwned(alloc, owned, try clean.toOwnedSlice(alloc));
    try words.append(alloc, owned.items[owned.items.len - 1]);
}

/// Expands fx's project variables and `~/` in one word. The caller owns a non-null result.
fn substitute(
    alloc: std.mem.Allocator,
    raw: []const u8,
    workspace_root: []const u8,
    home: ?[]const u8,
) std.mem.Allocator.Error!?[]u8 {
    var text = try alloc.dupe(u8, raw);
    errdefer alloc.free(text);

    text = try replace(alloc, text, "${FX_PROJECT_DIR}", workspace_root);
    text = try replace(alloc, text, "$FX_PROJECT_DIR", workspace_root);
    text = try replace(alloc, text, "${CLAUDE_PROJECT_DIR}", workspace_root);
    text = try replace(alloc, text, "$CLAUDE_PROJECT_DIR", workspace_root);

    const wants_home = std.mem.find(u8, text, "${HOME}") != null or
        std.mem.find(u8, text, "$HOME") != null or
        std.mem.startsWith(u8, text, "~/");
    if (wants_home) {
        const root = home orelse {
            alloc.free(text);
            return null;
        };
        text = try replace(alloc, text, "${HOME}", root);
        text = try replace(alloc, text, "$HOME", root);
        if (std.mem.startsWith(u8, text, "~/")) {
            const joined = try std.Io.Dir.path.join(alloc, &.{ root, text[2..] });
            alloc.free(text);
            return joined;
        }
    }
    return text;
}

/// Replaces every `needle` with `replacement`, freeing `text` when it copies.
fn replace(
    alloc: std.mem.Allocator,
    text: []u8,
    needle: []const u8,
    replacement: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (std.mem.find(u8, text, needle) == null) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, needle)) |at| {
        try out.appendSlice(alloc, rest[0..at]);
        try out.appendSlice(alloc, replacement);
        rest = rest[at + needle.len ..];
    }
    try out.appendSlice(alloc, rest);

    alloc.free(text);
    return out.toOwnedSlice(alloc);
}

/// The trust digest of one hook.
pub fn digest(
    alloc: std.mem.Allocator,
    hook: *const hooks.config.Hook,
    workspace_root: []const u8,
    files: []const []const u8,
) std.mem.Allocator.Error![Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    const zero = [_]u8{0};

    hasher.update(&hook.hash);
    hasher.update(@tagName(hook.layer));
    hasher.update(&zero);
    switch (hook.layer) {
        .project, .claude_project => {
            hasher.update(workspace_root);
            hasher.update(&zero);
        },
        else => {},
    }
    for (files) |file_path| try hashFile(alloc, &hasher, file_path);

    var out: [Sha256.digest_length]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Hashes what fx found at one path: a file's content; for a file too large to
/// read, its size and its change and modification times; or a word for a path
/// fx could not read.
fn hashFile(alloc: std.mem.Allocator, hasher: *Sha256, file_path: []const u8) std.mem.Allocator.Error!void {
    const io = io_mod.getIo();

    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
        hashTag(hasher, if (err == error.FileNotFound) "missing" else "other", file_path);
        return;
    };
    defer file.close(io);

    const stat = file.stat(io) catch {
        hashTag(hasher, "other", file_path);
        return;
    };
    if (stat.kind != .file) {
        hashTag(hasher, "other", file_path);
        return;
    }

    if (stat.size > max_content_bytes) {
        hashTag(hasher, "large", file_path);
        // A rewrite at the same size keeps the size, so the change and modification
        // times stand in for the content.
        const text = try alloc.print("{d} {d} {d}", .{ stat.size, stat.ctime.nanoseconds, stat.mtime.nanoseconds });
        defer alloc.free(text);
        hasher.update(text);
        hasher.update(&[_]u8{0});
        return;
    }

    var content_hasher = Sha256.init(.{});
    var chunk: [content_chunk]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                hashTag(hasher, "other", file_path);
                return;
            },
        };
        if (n == 0) break;
        content_hasher.update(chunk[0..n]);
    }
    var content: [Sha256.digest_length]u8 = undefined;
    content_hasher.final(&content);

    hashTag(hasher, "file", file_path);
    hasher.update(&content);
}

fn hashTag(hasher: *Sha256, tag: []const u8, file_path: []const u8) void {
    const zero = [_]u8{0};
    hasher.update(tag);
    hasher.update(&zero);
    hasher.update(file_path);
    hasher.update(&zero);
}

/// Whether `ai_agent`, the value of the AI_AGENT variable, means the caller is
/// fx's own agent, which may not give trust.
pub fn refusedForAgent(ai_agent: ?[]const u8) bool {
    const value = ai_agent orelse return false;
    return std.mem.eql(u8, value, "fx");
}

/// Lowercase hex of a digest.
pub fn hex(value: [Sha256.digest_length]u8) [hex_length]u8 {
    const digits = "0123456789abcdef";
    var text: [hex_length]u8 = undefined;
    for (value, 0..) |byte, index| {
        text[index * 2] = digits[byte >> 4];
        text[index * 2 + 1] = digits[byte & 0x0f];
    }
    return text;
}

/// Writes a fixture file that load accepts: mode 0600.
fn writeFixture(alloc: std.mem.Allocator, file_path: []const u8, text: []const u8) !void {
    try io_mod.writeFileAtomic(alloc, file_path, text);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
}

/// A shell command for a test; namedFiles never writes through the slice.
fn shellCommand(text: []const u8) hooks.config.Command {
    return .{ .shell = @constCast(text) };
}

fn argvCommand(items: [][]u8) hooks.config.Command {
    return .{ .argv = items };
}

test "a missing trust file is an empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "missing-trust.json" });
    defer alloc.free(file_path);

    var store = try load(alloc, file_path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "a saved store loads back with its mode and its labels" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "hooks-trust.json" });
    defer alloc.free(file_path);

    const first: [Sha256.digest_length]u8 = @splat(0x11);
    const second: [Sha256.digest_length]u8 = @splat(0x22);

    var store = Store{};
    defer store.deinit(alloc);
    try store.add(alloc, first, "first hook");
    try store.add(alloc, second, "second hook");
    try save(alloc, file_path, &store);

    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), file_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    var loaded = try load(alloc, file_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try std.testing.expect(loaded.contains(first));
    try std.testing.expect(loaded.contains(second));
    try std.testing.expectEqualStrings("first hook", loaded.entries.items[0].label);
    try std.testing.expectEqualStrings("second hook", loaded.entries.items[1].label);
}

test "a trust file others can write is refused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "hooks-trust.json" });
    defer alloc.free(file_path);

    try writeFixture(alloc, file_path, "{\"version\":1,\"trusted\":[]}");
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o664), .{});

    try std.testing.expectError(error.TrustFileUnsafe, load(alloc, file_path));
}

test "a trust file that is not what fx wrote is refused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "hooks-trust.json" });
    defer alloc.free(file_path);

    try writeFixture(alloc, file_path, "{not json");
    try std.testing.expectError(error.TrustFileInvalid, load(alloc, file_path));

    try writeFixture(alloc, file_path, "{\"version\":2,\"trusted\":[]}");
    try std.testing.expectError(error.TrustFileInvalid, load(alloc, file_path));

    const short_digest =
        "{\"version\":1,\"trusted\":[{\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"label\":\"x\"}]}";
    try writeFixture(alloc, file_path, short_digest);
    try std.testing.expectError(error.TrustFileInvalid, load(alloc, file_path));
}

test "hooks disabled per workspace save and load back" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "hooks-trust.json" });
    defer alloc.free(file_path);

    var store = Store{};
    defer store.deinit(alloc);
    try store.setDisabled(alloc, "/work/app", "lint", true);
    try store.setDisabled(alloc, "/work/other", "lint", true);
    try save(alloc, file_path, &store);

    var loaded = try load(alloc, file_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.disabled.items.len);
    try std.testing.expect(loaded.isDisabled("/work/app", "lint"));
    try std.testing.expect(loaded.isDisabled("/work/other", "lint"));
    try std.testing.expect(!loaded.isDisabled("/work/app", "other"));
    try std.testing.expect(!loaded.isDisabled("/work/third", "lint"));
}

test "an old trust file without a disabled list loads with none, and a bad list is refused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ root, "hooks-trust.json" });
    defer alloc.free(file_path);

    try writeFixture(alloc, file_path, "{\"version\":1,\"trusted\":[]}");
    var loaded = try load(alloc, file_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.disabled.items.len);

    // A list of the wrong shape makes the file invalid, as any other bad field does.
    try writeFixture(alloc, file_path, "{\"version\":1,\"trusted\":[],\"disabled\":\"lint\"}");
    try std.testing.expectError(error.TrustFileInvalid, load(alloc, file_path));
    try writeFixture(alloc, file_path, "{\"version\":1,\"trusted\":[],\"disabled\":[{\"workspace\":\"/w\"}]}");
    try std.testing.expectError(error.TrustFileInvalid, load(alloc, file_path));
}

test "setDisabled false clears the entry, and recording twice keeps one" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);

    try store.setDisabled(alloc, "/work/app", "lint", true);
    try store.setDisabled(alloc, "/work/app", "lint", true);
    try std.testing.expectEqual(@as(usize, 1), store.disabled.items.len);

    try store.setDisabled(alloc, "/work/app", "lint", false);
    try std.testing.expect(!store.isDisabled("/work/app", "lint"));
    try std.testing.expectEqual(@as(usize, 0), store.disabled.items.len);

    // Clearing a hook that is not disabled changes nothing.
    try store.setDisabled(alloc, "/work/app", "lint", false);
    try std.testing.expectEqual(@as(usize, 0), store.disabled.items.len);
}

test "named files come from the words that name a path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    {
        var named = try namedFiles(alloc, shellCommand("./scripts/check.sh --fix"), workspace, home);
        defer named.deinit(alloc);
        try expectNamed(alloc, named, workspace, &.{"scripts/check.sh"}, 0);
    }
    {
        var named = try namedFiles(alloc, shellCommand("python3 \"$FX_PROJECT_DIR/.fx/hooks/a.py\""), workspace, home);
        defer named.deinit(alloc);
        try expectNamed(alloc, named, workspace, &.{".fx/hooks/a.py"}, 0);
    }
    {
        var named = try namedFiles(alloc, shellCommand("bash ${CLAUDE_PROJECT_DIR}/x.sh && ./y.sh"), workspace, home);
        defer named.deinit(alloc);
        try expectNamed(alloc, named, workspace, &.{ "x.sh", "y.sh" }, 0);
    }
    {
        var named = try namedFiles(alloc, shellCommand("~/bin/guard"), workspace, home);
        defer named.deinit(alloc);
        const expected = try std.Io.Dir.path.join(alloc, &.{ home, "bin/guard" });
        defer alloc.free(expected);
        try std.testing.expectEqual(@as(usize, 1), named.files.len);
        try std.testing.expectEqualStrings(expected, named.files[0]);
    }
    {
        var named = try namedFiles(alloc, shellCommand("~/bin/guard"), workspace, null);
        defer named.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), named.files.len);
    }
    {
        var named = try namedFiles(alloc, shellCommand("sh $HOME/bin/x.sh"), workspace, home);
        defer named.deinit(alloc);
        const expected = try std.Io.Dir.path.join(alloc, &.{ home, "bin/x.sh" });
        defer alloc.free(expected);
        try std.testing.expectEqual(@as(usize, 1), named.files.len);
        try std.testing.expectEqualStrings(expected, named.files[0]);
    }
    {
        var named = try namedFiles(alloc, shellCommand("sh $HOME/bin/x.sh"), workspace, null);
        defer named.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), named.files.len);
    }
    {
        var named = try namedFiles(alloc, shellCommand("echo hi"), workspace, home);
        defer named.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), named.files.len);
    }
    {
        var argv = [_][]u8{ @constCast("/bin/sh"), @constCast("-c"), @constCast("./z.sh") };
        var named = try namedFiles(alloc, argvCommand(&argv), workspace, home);
        defer named.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), named.files.len);
        const z_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "z.sh" });
        defer alloc.free(z_path);
        var expected = [_][]u8{ z_path, @constCast("/bin/sh") };
        std.mem.sort([]u8, &expected, {}, lessThanPath);
        try std.testing.expectEqualStrings(expected[0], named.files[0]);
        try std.testing.expectEqualStrings(expected[1], named.files[1]);
    }
    {
        var argv = [_][]u8{ @constCast("bash"), @constCast("./scripts/check.sh") };
        var named = try namedFiles(alloc, argvCommand(&argv), workspace, home);
        defer named.deinit(alloc);
        try expectNamed(alloc, named, workspace, &.{"scripts/check.sh"}, 0);
    }
    {
        var argv = [_][]u8{@constCast("${HOME}/bin/y")};
        var named = try namedFiles(alloc, argvCommand(&argv), workspace, home);
        defer named.deinit(alloc);
        const expected = try std.Io.Dir.path.join(alloc, &.{ home, "bin/y" });
        defer alloc.free(expected);
        try std.testing.expectEqual(@as(usize, 1), named.files.len);
        try std.testing.expectEqualStrings(expected, named.files[0]);
    }
    {
        var shell_words: std.ArrayList(u8) = .empty;
        defer shell_words.deinit(alloc);
        var index: usize = 0;
        while (index < 70) : (index += 1) {
            if (index > 0) try shell_words.append(alloc, ' ');
            const piece = try alloc.print("./f{d}", .{index});
            defer alloc.free(piece);
            try shell_words.appendSlice(alloc, piece);
        }
        var named = try namedFiles(alloc, shellCommand(shell_words.items), workspace, home);
        defer named.deinit(alloc);
        try std.testing.expectEqual(@as(usize, max_named_files), named.files.len);
        try std.testing.expectEqual(@as(usize, 6), named.dropped);
    }
}

test "an output redirect to a log names no file" {
    const alloc = std.testing.allocator;
    var named = try namedFiles(alloc, shellCommand("echo x >> /tmp/log.txt"), "/w", null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), named.files.len);
}

test "a command that writes its input to a file names no file" {
    const alloc = std.testing.allocator;
    var named = try namedFiles(alloc, shellCommand("cat > '/w/start-input.json'"), "/w", null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), named.files.len);
}

test "an input redirect names the file it reads" {
    const alloc = std.testing.allocator;
    var named = try namedFiles(alloc, shellCommand("sh < /w/script.sh"), "/w", null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), named.files.len);
    try std.testing.expectEqualStrings("/w/script.sh", named.files[0]);
}

test "a file that the command writes and then runs is named through its run" {
    const alloc = std.testing.allocator;
    var named = try namedFiles(alloc, shellCommand("echo x > /w/a.sh; sh /w/a.sh"), "/w", null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), named.files.len);
    try std.testing.expectEqualStrings("/w/a.sh", named.files[0]);
}

test "a run that writes another file names only the file it runs" {
    const alloc = std.testing.allocator;
    var named = try namedFiles(alloc, shellCommand("python3 /w/hook.py > /w/out.txt"), "/w", null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), named.files.len);
    try std.testing.expectEqualStrings("/w/hook.py", named.files[0]);
}

test "a hook that appends to a log keeps its trust after a run changes the log" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const text = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo run >> ./run.log\"}]}]}}";
    var project_file = try hooks.config.parse(alloc, text, .{ .layer = .project });
    defer project_file.deinit(alloc);
    const hook = &project_file.hooks[0];
    var named = try namedFiles(alloc, hook.command, workspace, null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), named.files.len);

    const log_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "run.log" });
    defer alloc.free(log_path);
    try writeFixture(alloc, log_path, "run\n");
    const first = try digest(alloc, hook, workspace, named.files);
    try writeFixture(alloc, log_path, "run\nrun\n");
    const second = try digest(alloc, hook, workspace, named.files);
    try std.testing.expectEqual(first, second);
}

fn expectNamed(
    alloc: std.mem.Allocator,
    named: Named,
    workspace: []const u8,
    relative: []const []const u8,
    dropped: usize,
) !void {
    try std.testing.expectEqual(dropped, named.dropped);
    try std.testing.expectEqual(relative.len, named.files.len);

    var expected: std.ArrayList([]u8) = .empty;
    defer {
        for (expected.items) |item| alloc.free(item);
        expected.deinit(alloc);
    }
    for (relative) |part| {
        const joined = try std.Io.Dir.path.join(alloc, &.{ workspace, part });
        expected.append(alloc, joined) catch |err| {
            alloc.free(joined);
            return err;
        };
    }
    std.mem.sort([]u8, expected.items, {}, lessThanPath);
    for (expected.items, 0..) |expected_path, index| {
        try std.testing.expectEqualStrings(expected_path, named.files[index]);
    }
}

test "the digest covers the hook, its layer, its workspace, and its files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/scripts");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const other_workspace = try std.Io.Dir.path.join(alloc, &.{ workspace, "other" });
    defer alloc.free(other_workspace);

    const script = try std.Io.Dir.path.join(alloc, &.{ workspace, "scripts/check.sh" });
    defer alloc.free(script);
    try writeFixture(alloc, script, "echo 1");

    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./scripts/check.sh\"}]}]}}";
    var project_file = try hooks.config.parse(alloc, text, .{ .layer = .project });
    defer project_file.deinit(alloc);
    const project_hook = &project_file.hooks[0];
    var named = try namedFiles(alloc, project_hook.command, workspace, null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), named.files.len);

    const first = try digest(alloc, project_hook, workspace, named.files);
    const again = try digest(alloc, project_hook, workspace, named.files);
    try std.testing.expectEqual(first, again);

    try writeFixture(alloc, script, "echo 2");
    const changed = try digest(alloc, project_hook, workspace, named.files);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));

    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), script);
    const missing = try digest(alloc, project_hook, workspace, named.files);
    try std.testing.expect(!std.mem.eql(u8, &changed, &missing));
    try std.testing.expect(!std.mem.eql(u8, &first, &missing));

    var profile_file = try hooks.config.parse(alloc, text, .{ .layer = .profile });
    defer profile_file.deinit(alloc);
    const profile_digest = try digest(alloc, &profile_file.hooks[0], workspace, named.files);
    try std.testing.expect(!std.mem.eql(u8, &missing, &profile_digest));

    try writeFixture(alloc, script, "echo 1");
    var same_files = try namedFiles(alloc, project_hook.command, workspace, null);
    defer same_files.deinit(alloc);
    const project_again = try digest(alloc, project_hook, workspace, same_files.files);
    const other_place = try digest(alloc, project_hook, other_workspace, same_files.files);
    try std.testing.expect(!std.mem.eql(u8, &project_again, &other_place));
}

test "a large named file counts its change and modification times, so a same-size rewrite needs trust again" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./big.bin\"}]}]}}";
    var project_file = try hooks.config.parse(alloc, text, .{ .layer = .project });
    defer project_file.deinit(alloc);
    const hook = &project_file.hooks[0];
    var named = try namedFiles(alloc, hook.command, workspace, null);
    defer named.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), named.files.len);

    // A sparse file just over the cap. Only one byte is written, at offset 0.
    var file = try tmp.dir.createFile(io, "workspace/big.bin", .{});
    defer file.close(io);
    try file.setLength(io, max_content_bytes + 1);
    const first = try digest(alloc, hook, workspace, named.files);

    try file.writePositionalAll(io, "x", 0);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 } } });
    const second = try digest(alloc, hook, workspace, named.files);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "a write lock on a trust file is exclusive until it is released" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);
    const lock_path = try alloc.print("{s}.lock", .{file_path});
    defer alloc.free(lock_path);

    const first = try lockWriters(alloc, file_path, 1000);
    try std.testing.expectError(error.WouldBlock, std.Io.Dir.createFileAbsolute(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));
    first.release();

    const second = try lockWriters(alloc, file_path, 1000);
    second.release();
}

test "two locked updates in a row keep both changes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);

    {
        const lock = try lockWriters(alloc, file_path, 1000);
        defer lock.release();
        var store = try load(alloc, file_path);
        defer store.deinit(alloc);
        try store.add(alloc, @as([Sha256.digest_length]u8, @splat(7)), "first hook");
        try save(alloc, file_path, &store);
    }
    {
        const lock = try lockWriters(alloc, file_path, 1000);
        defer lock.release();
        var store = try load(alloc, file_path);
        defer store.deinit(alloc);
        try store.setDisabled(alloc, "/workspace", "guard", true);
        try save(alloc, file_path, &store);
    }

    var final = try load(alloc, file_path);
    defer final.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), final.entries.items.len);
    try std.testing.expect(final.isDisabled("/workspace", "guard"));
}

test "a temp name that already exists is skipped, never written" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);
    const planted = try alloc.print("{s}.tmp.0", .{file_path});
    defer alloc.free(planted);
    try writeFixture(alloc, planted, "keep me");

    var temp = try createTemp(alloc, io, file_path);
    defer alloc.free(temp.name);
    defer temp.file.close(io);
    try std.testing.expect(!std.mem.eql(u8, temp.name, planted));

    var kept = try std.Io.Dir.openFileAbsolute(io, planted, .{});
    defer kept.close(io);
    const text = try io_mod.readFileToEnd(alloc, &kept, 64);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("keep me", text);
}

test "a lock with no wait takes a free lock at once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);

    const lock = try lockWriters(alloc, file_path, 0);
    lock.release();
}

test "a trust file lock held by another writer times out as busy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);

    const held = try lockWriters(alloc, file_path, 1000);
    defer held.release();
    try std.testing.expectError(error.TrustFileBusy, lockWriters(alloc, file_path, 0));
}

test "fx's own agent may not give trust" {
    try std.testing.expect(refusedForAgent("fx"));
    try std.testing.expect(!refusedForAgent(null));
    try std.testing.expect(!refusedForAgent("codex"));
    try std.testing.expect(!refusedForAgent(""));
}
