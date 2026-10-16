//! Thread registry: named threads that stem from one root session.
//!
//! A thread is an ordinary saved session. The registry only records which
//! sessions belong together and what each is called, so it works with every
//! session backend and adds no field to session metadata. One file per root
//! lives at `~/.fx/threads/<root-id>.json`. The root session is the implicit
//! thread named `main`.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const root_thread_name = "main";
pub const max_name_bytes: usize = 32;
const max_file_bytes: usize = 1024 * 1024;
const schema_version: u32 = 1;

pub const Error = error{
    InvalidThreadName,
    ReservedThreadName,
    DuplicateThreadName,
    ThreadNotFound,
    InvalidRegistry,
};

pub const Thread = struct {
    /// What the user types.
    name: []u8,
    /// The persistent child's unique agent name. Never reused, so a deleted
    /// thread's name can come back without inheriting its history.
    agent: []u8,
    /// The thread's saved session. Empty until the thread has started.
    session_id: []u8,
    /// The start of the instructions it was given, on one line. Empty for
    /// threads saved before this was kept. Names are searched alongside it.
    title: []u8,
    created_at_ms: i64,
};

/// Owns every string it holds.
pub const Registry = struct {
    root_id: []u8,
    threads: std.ArrayList(Thread) = .empty,

    pub fn init(alloc: Allocator, root_id: []const u8) !Registry {
        return .{ .root_id = try alloc.dupe(u8, root_id) };
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.threads.items) |t| {
            alloc.free(t.name);
            alloc.free(t.agent);
            alloc.free(t.session_id);
            alloc.free(t.title);
        }
        self.threads.deinit(alloc);
        alloc.free(self.root_id);
        self.* = undefined;
    }

    /// The thread whose name is exactly `name`, ignoring case.
    pub fn find(self: *const Registry, name: []const u8) ?*const Thread {
        for (self.threads.items) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
        }
        return null;
    }

    pub const Ambiguous = struct {
        /// Up to four of the matching names.
        names: [4][]const u8 = undefined,
        /// How many threads matched in all.
        count: usize = 0,

        fn add(self: *Ambiguous, name: []const u8) void {
            if (self.count < self.names.len) self.names[self.count] = name;
            self.count += 1;
        }
    };

    pub const Resolution = union(enum) {
        found: *const Thread,
        none,
        ambiguous: Ambiguous,
    };

    /// Finds a thread from what a person typed, tolerant of case, partial
    /// names, word order, abbreviations, and small typos. Steps run from
    /// strict to loose and the first step that matches anything decides:
    /// the whole name, a name that starts with the text, a name with a word
    /// equal to it, then a name that contains it. After that every word typed
    /// must match a word of the name or of the instructions the thread was
    /// given (by prefix, then within a typo or two), and last the letters may
    /// be an abbreviation of the name. When one thread matches best it wins;
    /// when several match equally well they are reported, not guessed.
    pub fn resolve(self: *const Registry, query_text: []const u8) Resolution {
        const query = std.mem.trim(u8, query_text, " \t");
        if (query.len == 0) return .none;
        if (self.find(query)) |t| return .{ .found = t };
        const steps = [_]MatchKind{ .prefix, .word, .contains };
        for (steps) |kind| {
            var ambiguous = Ambiguous{};
            var first: ?*const Thread = null;
            for (self.threads.items) |*t| {
                if (!nameMatches(t.name, query, kind)) continue;
                ambiguous.add(t.name);
                if (first == null) first = t;
            }
            if (ambiguous.count == 1) return .{ .found = first.? };
            if (ambiguous.count > 1) return .{ .ambiguous = ambiguous };
        }
        const loose = [_]LooseKind{ .words, .typos, .abbreviation };
        for (loose) |kind| {
            var best = Ambiguous{};
            var best_thread: ?*const Thread = null;
            var best_score: usize = std.math.maxInt(usize);
            for (self.threads.items) |*t| {
                const score = looseScore(t, query, kind) orelse continue;
                if (score < best_score) {
                    best_score = score;
                    best = .{};
                    best_thread = t;
                }
                if (score == best_score) best.add(t.name);
            }
            if (best.count == 1) return .{ .found = best_thread.? };
            if (best.count > 1) return .{ .ambiguous = best };
        }
        return .none;
    }

    pub fn add(self: *Registry, alloc: Allocator, name: []const u8, agent: []const u8, now_ms: i64) !void {
        try validateName(name);
        if (self.find(name) != null) return error.DuplicateThreadName;
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_agent = try alloc.dupe(u8, agent);
        errdefer alloc.free(owned_agent);
        const owned_session = try alloc.dupe(u8, "");
        errdefer alloc.free(owned_session);
        const owned_title = try alloc.dupe(u8, "");
        errdefer alloc.free(owned_title);
        try self.threads.append(alloc, .{ .name = owned_name, .agent = owned_agent, .session_id = owned_session, .title = owned_title, .created_at_ms = now_ms });
    }

    /// Records what the thread was asked to do, shortened to one line.
    pub fn setTitle(self: *Registry, alloc: Allocator, name: []const u8, instructions: []const u8) !void {
        const index = self.indexOf(name) orelse return error.ThreadNotFound;
        const owned = try titleFromText(alloc, instructions);
        alloc.free(self.threads.items[index].title);
        self.threads.items[index].title = owned;
    }

    pub fn setSession(self: *Registry, alloc: Allocator, name: []const u8, session_id: []const u8) !void {
        const index = self.indexOf(name) orelse return error.ThreadNotFound;
        const owned = try alloc.dupe(u8, session_id);
        alloc.free(self.threads.items[index].session_id);
        self.threads.items[index].session_id = owned;
    }

    pub fn findBySession(self: *const Registry, session_id: []const u8) ?*const Thread {
        if (session_id.len == 0) return null;
        for (self.threads.items) |*t| {
            if (std.mem.eql(u8, t.session_id, session_id)) return t;
        }
        return null;
    }

    pub fn rename(self: *Registry, alloc: Allocator, old_name: []const u8, new_name: []const u8) !void {
        try validateName(new_name);
        const index = self.indexOf(old_name) orelse return error.ThreadNotFound;
        if (self.find(new_name)) |other| {
            if (other != &self.threads.items[index]) return error.DuplicateThreadName;
        }
        const owned = try alloc.dupe(u8, new_name);
        alloc.free(self.threads.items[index].name);
        self.threads.items[index].name = owned;
    }

    /// Drops the entry. The caller deletes the session it named.
    pub fn remove(self: *Registry, alloc: Allocator, name: []const u8) !void {
        const index = self.indexOf(name) orelse return error.ThreadNotFound;
        const t = self.threads.orderedRemove(index);
        alloc.free(t.name);
        alloc.free(t.agent);
        alloc.free(t.session_id);
        alloc.free(t.title);
    }

    fn indexOf(self: *const Registry, name: []const u8) ?usize {
        for (self.threads.items, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) return i;
        }
        return null;
    }
};

const LooseKind = enum { words, typos, abbreviation };

const max_title_bytes: usize = 100;

/// One line of `text` for a title: whitespace collapsed, cut on a character
/// boundary with a trailing ellipsis when it is long. Caller owns the result.
pub fn titleFromText(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var cut = false;
    while (words.next()) |word| {
        const separator: usize = if (out.items.len == 0) 0 else 1;
        if (out.items.len + separator + word.len > max_title_bytes) {
            // Take what fits of the word, on a character boundary.
            var fit = max_title_bytes -| (out.items.len + separator);
            while (fit > 0 and fit < word.len and (word[fit] & 0xC0) == 0x80) fit -= 1;
            if (fit > 0) {
                if (separator == 1) try out.append(alloc, ' ');
                try out.appendSlice(alloc, word[0..fit]);
            }
            cut = true;
            break;
        }
        if (separator == 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, word);
    }
    if (cut) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Edits (insert, delete, replace, swap two neighbours) between `a` and `b`,
/// ignoring case. Words past 40 bytes compare on their first 40.
fn editDistance(a_full: []const u8, b_full: []const u8) usize {
    const a = a_full[0..@min(a_full.len, 40)];
    const b = b_full[0..@min(b_full.len, 40)];
    var rows: [3][41]u8 = undefined;
    var older = &rows[0];
    var previous = &rows[1];
    var current = &rows[2];
    for (0..b.len + 1) |j| previous[j] = @intCast(j);
    for (1..a.len + 1) |i| {
        current[0] = @intCast(i);
        for (1..b.len + 1) |j| {
            const x = std.ascii.toLower(a[i - 1]);
            const y = std.ascii.toLower(b[j - 1]);
            const cost: u8 = if (x == y) 0 else 1;
            var best = @min(@min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
            if (i > 1 and j > 1 and x == std.ascii.toLower(b[j - 2]) and std.ascii.toLower(a[i - 2]) == y) {
                best = @min(best, older[j - 2] + 1);
            }
            current[j] = best;
        }
        const recycled = older;
        older = previous;
        previous = current;
        current = recycled;
    }
    return previous[b.len];
}

/// How many typos a word of this length may carry and still be the same word.
fn typoAllowance(len: usize) usize {
    if (len < 4) return 0;
    if (len < 8) return 1;
    return 2;
}

/// The smallest cost at which `token` matches a word of `text`: 0 when a word
/// starts with it, or its edit distance when `typos` allows it. Null when no
/// word matches.
fn tokenCost(text: []const u8, token: []const u8, typos: bool) ?usize {
    var best: ?usize = null;
    var at: usize = 0;
    while (at < text.len) {
        while (at < text.len and !isWordByte(text[at])) at += 1;
        const start = at;
        while (at < text.len and isWordByte(text[at])) at += 1;
        const word = text[start..at];
        if (word.len == 0) continue;
        if (word.len >= token.len and std.ascii.eqlIgnoreCase(word[0..token.len], token)) return 0;
        if (!typos) continue;
        const allowed = typoAllowance(token.len);
        if (allowed == 0) continue;
        // A typo in a longer word still counts when its start is close.
        const compared = word[0..@min(word.len, token.len + 1)];
        const distance = @min(editDistance(word, token), editDistance(compared, token));
        if (distance <= allowed and (best == null or distance < best.?)) best = distance;
    }
    return best;
}

/// Lower is a better match; null is no match.
fn looseScore(t: *const Thread, query: []const u8, kind: LooseKind) ?usize {
    switch (kind) {
        .abbreviation => {
            var letters: [64]u8 = undefined;
            var count: usize = 0;
            for (query) |c| {
                if (!std.ascii.isAlphanumeric(c)) continue;
                if (count == letters.len) return null;
                letters[count] = std.ascii.toLower(c);
                count += 1;
            }
            if (count < 3) return null;
            var next: usize = 0;
            for (t.name) |c| {
                if (next < count and std.ascii.toLower(c) == letters[next]) next += 1;
            }
            // Shorter names that hold the letters are the tighter fit.
            return if (next == count) t.name.len else null;
        },
        .words, .typos => {
            const typos = kind == .typos;
            var total: usize = 0;
            var tokens: usize = 0;
            var it = std.mem.tokenizeAny(u8, query, " \t-_.,:;/");
            while (it.next()) |token| {
                tokens += 1;
                // A word in the name is a closer match than one in the instructions.
                if (tokenCost(t.name, token, typos)) |cost| {
                    total += cost;
                } else if (tokenCost(t.title, token, typos)) |cost| {
                    total += cost + 1;
                } else return null;
            }
            return if (tokens == 0) null else total;
        },
    }
}

const MatchKind = enum { prefix, word, contains };

fn nameMatches(name: []const u8, query: []const u8, kind: MatchKind) bool {
    switch (kind) {
        .prefix => return name.len >= query.len and std.ascii.eqlIgnoreCase(name[0..query.len], query),
        .word => {
            var words = std.mem.tokenizeAny(u8, name, "-_");
            while (words.next()) |word| {
                if (std.ascii.eqlIgnoreCase(word, query)) return true;
            }
            return false;
        },
        .contains => {
            if (query.len > name.len) return false;
            var at: usize = 0;
            while (at + query.len <= name.len) : (at += 1) {
                if (std.ascii.eqlIgnoreCase(name[at .. at + query.len], query)) return true;
            }
            return false;
        },
    }
}

/// Names are mention-safe: `@thread:NAME` must parse without quoting.
pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidThreadName;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return error.InvalidThreadName;
    for (name[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_') return error.InvalidThreadName;
    }
    if (std.mem.eql(u8, name, root_thread_name)) return error.ReservedThreadName;
}

const suggest_max_words: usize = 5;

/// Words that carry no meaning in a name, so `search up more about rishav`
/// is named `search-rishav` and `@thread:rishav` finds it.
fn isFillerWord(word: []const u8) bool {
    const filler = [_][]const u8{
        "a",    "an", "the",  "of",   "to", "for",  "and",    "or",   "about", "up",
        "more", "on", "in",   "with", "me", "my",   "please", "can",  "you",   "could",
        "i",    "it", "is",   "are",  "be", "this", "that",   "some", "any",   "also",
        "just", "go", "then", "so",   "at", "from", "into",   "out",  "over",  "do",
    };
    for (filler) |f| {
        if (std.mem.eql(u8, word, f)) return true;
    }
    return false;
}

/// A thread name for free-form instructions: the first few words as a slug,
/// made unique among `registry`'s threads and never `main`. Caller owns the
/// result.
pub fn suggestName(alloc: Allocator, registry: *const Registry, instructions: []const u8) Allocator.Error![]u8 {
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(alloc);
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, instructions, " \t\r\n");
    while (it.next()) |raw| {
        if (words == suggest_max_words) break;
        var word: [max_name_bytes]u8 = undefined;
        var len: usize = 0;
        for (raw) |c| {
            if (len == word.len) break;
            if (std.ascii.isAlphanumeric(c)) {
                word[len] = std.ascii.toLower(c);
                len += 1;
            } else if (len > 0 and word[len - 1] != '-') {
                word[len] = '-';
                len += 1;
            }
        }
        while (len > 0 and word[len - 1] == '-') len -= 1;
        if (len == 0) continue;
        if (isFillerWord(word[0..len])) continue;
        const separator: usize = if (base.items.len == 0) 0 else 1;
        if (base.items.len + separator + len > max_name_bytes) break;
        if (separator == 1) try base.append(alloc, '-');
        try base.appendSlice(alloc, word[0..len]);
        words += 1;
    }
    if (base.items.len == 0) try base.appendSlice(alloc, "thread");

    // Leave room for a "-N" suffix when the plain name is taken.
    var candidate = try alloc.dupe(u8, base.items);
    errdefer alloc.free(candidate);
    var n: usize = 1;
    while (registry.find(candidate) != null or std.mem.eql(u8, candidate, root_thread_name)) {
        n += 1;
        alloc.free(candidate);
        var suffix_buf: [16]u8 = undefined;
        const suffix = std.mem.print(&suffix_buf, "-{d}", .{n}) catch unreachable;
        const keep = @min(base.items.len, max_name_bytes - suffix.len);
        candidate = try std.mem.concat(alloc, u8, &.{ std.mem.trimEnd(u8, base.items[0..keep], "-"), suffix });
    }
    return candidate;
}

/// The agent name behind a thread. `unique` is any short string unique per
/// creation, such as a timestamp in hex. Caller owns the result.
pub fn agentNameFor(alloc: Allocator, name: []const u8, unique: u64) ![]u8 {
    return alloc.print("th-{x}-{s}", .{ unique, name });
}

/// The user-facing name inside a thread's agent name, or null when `agent`
/// does not come from `agentNameFor`.
pub fn nameFromAgent(agent: []const u8) ?[]const u8 {
    const prefix = "th-";
    if (!std.mem.startsWith(u8, agent, prefix)) return null;
    const rest = agent[prefix.len..];
    const dash = std.mem.findScalar(u8, rest, '-') orelse return null;
    if (dash == 0 or dash + 1 >= rest.len) return null;
    return rest[dash + 1 ..];
}

/// Caller owns the result.
pub fn registryPath(alloc: Allocator, home: []const u8, root_id: []const u8) ![]u8 {
    const file_name = try alloc.print("{s}.json", .{root_id});
    defer alloc.free(file_name);
    return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, profile_paths.threads_dir_name, file_name });
}

/// An unreadable or missing file yields an empty registry only for
/// `FileNotFound`; corrupt content is an error so it is never overwritten.
pub fn load(alloc: Allocator, home: []const u8, root_id: []const u8) !Registry {
    var registry = try Registry.init(alloc, root_id);
    errdefer registry.deinit(alloc);

    const path = try registryPath(alloc, home, root_id);
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return registry,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidRegistry;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRegistry,
    };
    const version = switch (obj.get("schema_version") orelse return error.InvalidRegistry) {
        .integer => |i| i,
        else => return error.InvalidRegistry,
    };
    if (version != schema_version) return error.InvalidRegistry;
    const items = switch (obj.get("threads") orelse return error.InvalidRegistry) {
        .array => |a| a.items,
        else => return error.InvalidRegistry,
    };
    for (items) |item| {
        const o = switch (item) {
            .object => |o| o,
            else => return error.InvalidRegistry,
        };
        const name = stringField(o, "name") orelse return error.InvalidRegistry;
        const agent = stringField(o, "agent") orelse return error.InvalidRegistry;
        const created: i64 = switch (o.get("created_at_ms") orelse return error.InvalidRegistry) {
            .integer => |i| i,
            else => return error.InvalidRegistry,
        };
        registry.add(alloc, name, agent, created) catch return error.InvalidRegistry;
        if (stringField(o, "session_id")) |session_id| {
            if (session_id.len > 0) registry.setSession(alloc, name, session_id) catch return error.InvalidRegistry;
        }
        if (stringField(o, "title")) |title| {
            if (title.len > 0) registry.setTitle(alloc, name, title) catch return error.InvalidRegistry;
        }
    }
    return registry;
}

pub fn save(alloc: Allocator, home: []const u8, registry: *const Registry) !void {
    const path = try registryPath(alloc, home, registry.root_id);
    defer alloc.free(path);
    if (std.Io.Dir.path.dirname(path)) |dir| try io_mod.makeDirRecursive(dir);

    const Row = struct { name: []const u8, agent: []const u8, session_id: []const u8, title: []const u8, created_at_ms: i64 };
    const rows = try alloc.alloc(Row, registry.threads.items.len);
    defer alloc.free(rows);
    for (registry.threads.items, rows) |t, *row| {
        row.* = .{ .name = t.name, .agent = t.agent, .session_id = t.session_id, .title = t.title, .created_at_ms = t.created_at_ms };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .schema_version = schema_version,
        .root_id = registry.root_id,
        .threads = rows,
    }, .{}, &out.writer);
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

/// The registry that lists `session_id` as one of its threads, or null.
/// Caller owns the result.
pub fn loadForThreadSession(alloc: Allocator, home: []const u8, session_id: []const u8) !?Registry {
    const dir_path = try std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, profile_paths.threads_dir_name });
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const root_id = entry.name[0 .. entry.name.len - ".json".len];
        var registry = load(alloc, home, root_id) catch continue;
        if (registry.findBySession(session_id) != null) return registry;
        registry.deinit(alloc);
    }
    return null;
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

test "thread names are mention-safe and never claim main" {
    try validateName("fix-auth");
    try validateName("a_b-1");
    try std.testing.expectError(error.InvalidThreadName, validateName(""));
    try std.testing.expectError(error.InvalidThreadName, validateName("has space"));
    try std.testing.expectError(error.InvalidThreadName, validateName("Upper"));
    try std.testing.expectError(error.InvalidThreadName, validateName("-lead"));
    try std.testing.expectError(error.InvalidThreadName, validateName(&@as([33]u8, @splat('a'))));
    try std.testing.expectError(error.ReservedThreadName, validateName("main"));
}

test "registry add, rename, remove keep names unique" {
    const alloc = std.testing.allocator;
    var r = try Registry.init(alloc, "root1");
    defer r.deinit(alloc);
    try r.add(alloc, "alpha", "th-1-alpha", 1);
    try r.add(alloc, "beta", "th-2-beta", 2);
    try std.testing.expectError(error.DuplicateThreadName, r.add(alloc, "alpha", "th-3-alpha", 3));
    try std.testing.expectError(error.DuplicateThreadName, r.rename(alloc, "alpha", "beta"));
    try r.rename(alloc, "alpha", "gamma");
    try std.testing.expectEqualStrings("th-1-alpha", r.find("gamma").?.agent);
    try r.remove(alloc, "beta");
    try std.testing.expect(r.find("beta") == null);
    try std.testing.expectError(error.ThreadNotFound, r.remove(alloc, "beta"));
}

test "registry round trips through disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var missing = try load(alloc, home, "root1");
    defer missing.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), missing.threads.items.len);

    var r = try Registry.init(alloc, "root1");
    defer r.deinit(alloc);
    try r.add(alloc, "alpha", "th-1-alpha", 10);
    try save(alloc, home, &r);

    var loaded = try load(alloc, home, "root1");
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 10), loaded.find("alpha").?.created_at_ms);
    try std.testing.expectEqualStrings("th-1-alpha", loaded.find("alpha").?.agent);

    try loaded.setSession(alloc, "alpha", "sess-9");
    try save(alloc, home, &loaded);
    var from_thread = (try loadForThreadSession(alloc, home, "sess-9")).?;
    defer from_thread.deinit(alloc);
    try std.testing.expectEqualStrings("root1", from_thread.root_id);
    try std.testing.expect(try loadForThreadSession(alloc, home, "other") == null);
}

test "thread names come back out of agent names" {
    try std.testing.expectEqualStrings("fix-auth", nameFromAgent("th-abc123-fix-auth").?);
    try std.testing.expect(nameFromAgent("reviewer") == null);
    try std.testing.expect(nameFromAgent("th-abc") == null);
    try std.testing.expect(nameFromAgent("th--x") == null);
}

test "agent names are valid subagent names" {
    const alloc = std.testing.allocator;
    const agent = try agentNameFor(alloc, "fix-auth", 0xabc123);
    defer alloc.free(agent);
    try std.testing.expectEqualStrings("th-abc123-fix-auth", agent);
}

test "suggested names are a slug of the first words and stay valid" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);

    const plain = try suggestName(alloc, &registry, "Fix the login bug after a token refresh");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("fix-login-bug-after-token", plain);

    const filler = try suggestName(alloc, &registry, "search up more about rishav");
    defer alloc.free(filler);
    try std.testing.expectEqualStrings("search-rishav", filler);
    try validateName(plain);

    const punctuated = try suggestName(alloc, &registry, "  ...Add `foo.bar` & tests!!  ");
    defer alloc.free(punctuated);
    try std.testing.expectEqualStrings("add-foo-bar-tests", punctuated);
    try validateName(punctuated);

    const empty = try suggestName(alloc, &registry, "!!! ???");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("thread", empty);

    const long = try suggestName(alloc, &registry, "internationalization-and-localization-infrastructure-overhaul now");
    defer alloc.free(long);
    try std.testing.expect(long.len <= max_name_bytes);
    try validateName(long);
}

test "suggested names avoid taken names and main" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "fix-bug", "th-1-fix-bug", 1);

    const second = try suggestName(alloc, &registry, "fix the bug");
    defer alloc.free(second);
    try std.testing.expectEqualStrings("fix-bug-2", second);
    try registry.add(alloc, second, "th-2-x", 2);

    const third = try suggestName(alloc, &registry, "fix the bug");
    defer alloc.free(third);
    try std.testing.expectEqualStrings("fix-bug-3", third);

    const main_named = try suggestName(alloc, &registry, "main");
    defer alloc.free(main_named);
    try std.testing.expectEqualStrings("main-2", main_named);
    try validateName(main_named);
}

test "threads resolve from what a person types, ignoring case, by prefix, word, or part" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "search-up-more-about-rishav", "th-1-a", 1);
    try registry.add(alloc, "fix-login-bug", "th-2-b", 2);
    try registry.add(alloc, "fix-logout", "th-3-c", 3);

    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("RISHAV").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("rishav").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("SEARCH").found.name);
    try std.testing.expectEqualStrings("fix-login-bug", registry.resolve("Fix-Login-Bug").found.name);
    try std.testing.expectEqualStrings("fix-login-bug", registry.resolve("bug").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("ishav").found.name);

    // Several matches are reported, not guessed.
    const fix = registry.resolve("fix").ambiguous;
    try std.testing.expectEqual(@as(usize, 2), fix.count);
    try std.testing.expectEqualStrings("fix-login-bug", fix.names[0]);
    try std.testing.expect(registry.resolve("nothing") == .none);
    try std.testing.expect(registry.resolve("") == .none);
}

test "titles are one line, bounded, and cut on a character boundary" {
    const alloc = std.testing.allocator;
    const short = try titleFromText(alloc, "  fix the\n login   bug ");
    defer alloc.free(short);
    try std.testing.expectEqualStrings("fix the login bug", short);

    const long = try titleFromText(alloc, text_utils.repeat("word ", 40));
    defer alloc.free(long);
    try std.testing.expect(long.len <= max_title_bytes + "…".len);
    try std.testing.expect(std.mem.endsWith(u8, long, "…"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));

    const wide = try titleFromText(alloc, text_utils.repeat("é", 80));
    defer alloc.free(wide);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide));
}

test "edit distance counts typos and swapped letters" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("rishav", "RISHAV"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("rishva", "rishav"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("vercle", "vercel"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("kitten", "sitten") + 1);
    try std.testing.expect(editDistance("abc", "xyz") == 3);
}

test "threads resolve across word order, typos, instructions, and abbreviations" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "search-rishav", "th-1-a", 1);
    try registry.setTitle(alloc, "search-rishav", "search up more about rishav and his projects");
    try registry.add(alloc, "learn-vercel-edge", "th-2-b", 2);
    try registry.setTitle(alloc, "learn-vercel-edge", "learn more about vercel edge functions and pricing");
    try registry.add(alloc, "fix-login-bug", "th-3-c", 3);

    // Words in any order.
    try std.testing.expectEqualStrings("learn-vercel-edge", registry.resolve("edge vercel").found.name);
    try std.testing.expectEqualStrings("search-rishav", registry.resolve("rishav search").found.name);
    // Words that only the instructions hold.
    try std.testing.expectEqualStrings("learn-vercel-edge", registry.resolve("pricing").found.name);
    try std.testing.expectEqualStrings("search-rishav", registry.resolve("his projects").found.name);
    // Typos, in the name or the instructions.
    try std.testing.expectEqualStrings("search-rishav", registry.resolve("rishva").found.name);
    try std.testing.expectEqualStrings("learn-vercel-edge", registry.resolve("vercle").found.name);
    try std.testing.expectEqualStrings("learn-vercel-edge", registry.resolve("princing").found.name);
    // Abbreviations.
    try std.testing.expectEqualStrings("fix-login-bug", registry.resolve("flb").found.name);
    try std.testing.expectEqualStrings("search-rishav", registry.resolve("srchrsh").found.name);
    // Too far from anything.
    try std.testing.expect(registry.resolve("kubernetes") == .none);
    try std.testing.expect(registry.resolve("zz") == .none);
}

test "equally good fuzzy matches are reported, not guessed" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "alpha-docs", "th-1-a", 1);
    try registry.add(alloc, "beta-docs", "th-2-b", 2);
    try registry.setTitle(alloc, "alpha-docs", "write the api reference");
    try registry.setTitle(alloc, "beta-docs", "write the api guide");
    const r = registry.resolve("api").ambiguous;
    try std.testing.expectEqual(@as(usize, 2), r.count);
    // One thread that names it is a better match than one that only mentions it.
    try registry.add(alloc, "api-client", "th-3-c", 3);
    try std.testing.expectEqualStrings("api-client", registry.resolve("api").found.name);
}
