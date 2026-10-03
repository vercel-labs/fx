//! The live view's rules: what the user sees, where each key goes, and when
//! the view returns to main. Pure: the caller does the terminal work.
const std = @import("std");

/// The keys the view acts on. In a child's view only Ctrl+T is one; every
/// other byte goes to the child unchanged.
pub const Key = enum { ctrl_t, up, down, enter, escape };

pub const KeySet = std.EnumSet(Key);

/// The bytes main's terminal may send for each key: legacy bytes, the kitty
/// keyboard protocol and xterm's modifyOtherKeys, which fx turns on. A kitty
/// report may add Caps Lock (64) and Num Lock (128) to its modifier value;
/// main ignores those lock states, and so do these forms.
const forms = [_]struct { bytes: []const u8, key: Key }{
    .{ .bytes = "\x14", .key = .ctrl_t },
    .{ .bytes = "\x1b[116;5u", .key = .ctrl_t },
    .{ .bytes = "\x1b[116;69u", .key = .ctrl_t },
    .{ .bytes = "\x1b[116;133u", .key = .ctrl_t },
    .{ .bytes = "\x1b[116;197u", .key = .ctrl_t },
    .{ .bytes = "\x1b[27;5;116~", .key = .ctrl_t },
    .{ .bytes = "\x1b[A", .key = .up },
    .{ .bytes = "\x1bOA", .key = .up },
    .{ .bytes = "\x1b[B", .key = .down },
    .{ .bytes = "\x1bOB", .key = .down },
    .{ .bytes = "\r", .key = .enter },
    .{ .bytes = "\x1b[13u", .key = .enter },
    .{ .bytes = "\x1b[13;65u", .key = .enter },
    .{ .bytes = "\x1b[13;129u", .key = .enter },
    .{ .bytes = "\x1b[13;193u", .key = .enter },
    .{ .bytes = "\x1b[27u", .key = .escape },
    .{ .bytes = "\x1b[27;65u", .key = .escape },
    .{ .bytes = "\x1b[27;129u", .key = .escape },
    .{ .bytes = "\x1b[27;193u", .key = .escape },
    // A lone escape is known only once no more bytes follow it.
    .{ .bytes = "\x1b", .key = .escape },
};

const max_form = blk: {
    var len = 0;
    for (forms) |form| len = @max(len, form.bytes.len);
    break :blk len;
};

/// How long a possible key's first bytes wait for the rest.
pub const escape_timeout_ms: i64 = 25;

/// Splits the user's bytes into keys the view acts on and bytes it passes
/// on. Bytes that could still begin a key wait, at most `escape_timeout_ms`.
pub const Matcher = struct {
    held: [max_form]u8 = undefined,
    len: usize = 0,
    since_ms: i64 = 0,

    /// Passed bytes come first, in order, then the key. `pass` points into
    /// the caller's buffer.
    pub const Result = struct {
        pass: []const u8 = "",
        key: ?Key = null,
    };

    pub const Buffer = [max_form]u8;

    pub fn feed(self: *Matcher, keys: KeySet, byte: u8, now_ms: i64, buf: *Buffer) Result {
        std.debug.assert(self.len < max_form);
        self.held[self.len] = byte;
        self.len += 1;
        switch (classify(keys, self.held[0..self.len])) {
            .key => |key| {
                self.len = 0;
                return .{ .key = key };
            },
            .prefix => {
                if (self.len == 1) self.since_ms = now_ms;
                return .{};
            },
            .none => {},
        }
        // The older bytes pass; the last one may begin a key of its own.
        const older = self.len - 1;
        @memcpy(buf[0..older], self.held[0..older]);
        self.len = 0;
        switch (classify(keys, &.{byte})) {
            .key => |key| return .{ .pass = buf[0..older], .key = key },
            .prefix => {
                self.held[0] = byte;
                self.len = 1;
                self.since_ms = now_ms;
                return .{ .pass = buf[0..older] };
            },
            .none => {
                buf[older] = byte;
                return .{ .pass = buf[0 .. older + 1] };
            },
        }
    }

    /// Ends a wait that ran past the timeout: the held bytes are a key if
    /// they are one whole, else they pass.
    pub fn expire(self: *Matcher, keys: KeySet, now_ms: i64, buf: *Buffer) Result {
        if (self.len == 0 or now_ms - self.since_ms < escape_timeout_ms) return .{};
        const held = self.held[0..self.len];
        self.len = 0;
        if (whole(keys, held)) |key| return .{ .key = key };
        @memcpy(buf[0..held.len], held);
        return .{ .pass = buf[0..held.len] };
    }

    pub fn waiting(self: Matcher) bool {
        return self.len > 0;
    }

    const Class = union(enum) { key: Key, prefix, none };

    fn classify(keys: KeySet, held: []const u8) Class {
        var prefix = false;
        for (forms) |form| {
            if (!keys.contains(form.key)) continue;
            if (form.bytes.len > held.len and std.mem.startsWith(u8, form.bytes, held)) prefix = true;
        }
        if (prefix) return .prefix;
        if (whole(keys, held)) |key| return .{ .key = key };
        return .none;
    }

    fn whole(keys: KeySet, held: []const u8) ?Key {
        for (forms) |form| {
            if (keys.contains(form.key) and std.mem.eql(u8, form.bytes, held)) return form.key;
        }
        return null;
    }
};

pub const Mode = enum { main, picker, view };

/// Which screen the user sees, and which child is on it. `Handle` names a
/// child the way its runtime does.
pub fn View(comptime Handle: type) type {
    return struct {
        const Self = @This();

        mode: Mode = .main,
        viewed: ?Handle = null,
        /// The picker's highlighted row.
        selected: usize = 0,
        matcher: Matcher = .{},

        /// Ctrl+T on main. Refused while main asks the user something;
        /// otherwise the user could reopen the picker before main's prompt
        /// takes the screen, again and again, and the prompt would never show.
        pub fn open(self: *Self, main_asks: bool) bool {
            if (self.mode != .main or main_asks) return false;
            self.* = .{ .mode = .picker };
            return true;
        }

        pub fn move(self: *Self, key: Key, rows: usize) void {
            std.debug.assert(self.mode == .picker);
            if (rows == 0) return;
            self.selected = switch (key) {
                .up => if (self.selected == 0) rows - 1 else self.selected - 1,
                .down => (self.selected + 1) % rows,
                else => unreachable,
            };
        }

        pub fn choose(self: *Self, handle: Handle) void {
            std.debug.assert(self.mode == .picker);
            self.mode = .view;
            self.viewed = handle;
            self.matcher = .{};
        }

        /// Back to main. The caller releases the screen and asks main for a
        /// full repaint.
        pub fn leave(self: *Self) void {
            self.* = .{};
        }

        /// Checked every tick: a view leaves by itself only when its child is
        /// gone. Main's own prompts wait for the user: pulling the user back
        /// would hand main's prompt the next key, meant for the child.
        pub fn mustLeave(self: Self, child_gone: bool) bool {
            return self.mode == .view and child_gone;
        }

        /// The keys the current screen acts on.
        pub fn keys(self: Self) KeySet {
            return switch (self.mode) {
                .main => .initEmpty(),
                .picker => .initFull(),
                .view => .initOne(.ctrl_t),
            };
        }
    };
}

const testing = std.testing;

fn feedAll(matcher: *Matcher, keys: KeySet, bytes: []const u8, passed: *std.ArrayList(u8), found: *std.ArrayList(Key)) !void {
    var buf: Matcher.Buffer = undefined;
    for (bytes) |byte| {
        const result = matcher.feed(keys, byte, 0, &buf);
        try passed.appendSlice(testing.allocator, result.pass);
        if (result.key) |key| try found.append(testing.allocator, key);
    }
}

test "every Ctrl+T form leaves a view and other bytes pass unchanged" {
    const view_keys = KeySet.initOne(.ctrl_t);
    for ([_][]const u8{ "\x14", "\x1b[116;5u", "\x1b[116;69u", "\x1b[116;133u", "\x1b[116;197u", "\x1b[27;5;116~" }) |form| {
        var matcher: Matcher = .{};
        var passed: std.ArrayList(u8) = .empty;
        defer passed.deinit(testing.allocator);
        var found: std.ArrayList(Key) = .empty;
        defer found.deinit(testing.allocator);
        const typed = "ab\x1b[A\x1b[1;5C\r";
        try feedAll(&matcher, view_keys, typed, &passed, &found);
        try feedAll(&matcher, view_keys, form, &passed, &found);
        try testing.expectEqualStrings(typed, passed.items);
        try testing.expectEqualSlices(Key, &.{.ctrl_t}, found.items);
        try testing.expect(!matcher.waiting());
    }
}

test "a byte that breaks a held sequence may begin a key itself" {
    var matcher: Matcher = .{};
    var passed: std.ArrayList(u8) = .empty;
    defer passed.deinit(testing.allocator);
    var found: std.ArrayList(Key) = .empty;
    defer found.deinit(testing.allocator);
    try feedAll(&matcher, .initOne(.ctrl_t), "\x1b[1\x14\x1b\x1b[116;5u", &passed, &found);
    try testing.expectEqualStrings("\x1b[1\x1b", passed.items);
    try testing.expectEqualSlices(Key, &.{ .ctrl_t, .ctrl_t }, found.items);
}

test "a lone escape waits for the timeout, then passes or is a key" {
    var buf: Matcher.Buffer = undefined;
    var matcher: Matcher = .{};
    const view_keys = KeySet.initOne(.ctrl_t);
    const held = matcher.feed(view_keys, 0x1b, 100, &buf);
    try testing.expect(held.pass.len == 0 and held.key == null);
    try testing.expectEqual(@as(usize, 0), matcher.expire(view_keys, 100 + escape_timeout_ms - 1, &buf).pass.len);
    try testing.expectEqualStrings("\x1b", matcher.expire(view_keys, 100 + escape_timeout_ms, &buf).pass);

    _ = matcher.feed(.initFull(), 0x1b, 200, &buf);
    try testing.expectEqual(@as(?Key, .escape), matcher.expire(.initFull(), 200 + escape_timeout_ms, &buf).key);
}

test "the picker reads arrows, enter and escape in each form" {
    var matcher: Matcher = .{};
    var passed: std.ArrayList(u8) = .empty;
    defer passed.deinit(testing.allocator);
    var found: std.ArrayList(Key) = .empty;
    defer found.deinit(testing.allocator);
    try feedAll(&matcher, .initFull(), "\x1b[B\x1bOA\r\x1b[13u\x1b[13;65u\x1b[27u\x1b[27;129ux", &passed, &found);
    try testing.expectEqualSlices(Key, &.{ .down, .up, .enter, .enter, .enter, .escape, .escape }, found.items);
    try testing.expectEqualStrings("x", passed.items);
}

test "the view opens only from main while main asks nothing" {
    var view: View(u8) = .{};
    try testing.expect(!view.open(true));
    try testing.expect(view.open(false));
    try testing.expect(!view.open(false));
    view.move(.up, 3);
    try testing.expectEqual(@as(usize, 2), view.selected);
    view.move(.down, 3);
    try testing.expectEqual(@as(usize, 0), view.selected);
    view.choose(7);
    try testing.expect(view.keys().eql(.initOne(.ctrl_t)));
    try testing.expect(!view.mustLeave(false));
    try testing.expect(view.mustLeave(true));
    view.leave();
    try testing.expectEqual(Mode.main, view.mode);
    try testing.expectEqual(@as(?u8, null), view.viewed);
}

// Random runs. Each run drives the real View and Matcher with real key
// bytes, while the test plays the app around them:
// the screen owner, main's own prompts and main's paints. After every step
// it checks that a viewed child received exactly the bytes typed into it.

const Sim = struct {
    const Owner = enum { none, view, prompt };
    const MainScreen = enum { current, stale };
    const children = 2;

    view: View(u8) = .{},
    alive: [children]bool = .{ true, true },
    owner: Owner = .none,
    prompt: bool = false,
    key_to: ?[]const u8 = null,
    main_screen: MainScreen = .current,
    redraw: bool = false,
    now_ms: i64 = 0,

    fn leave(self: *Sim) void {
        self.view.leave();
        self.owner = .none;
        self.redraw = true;
    }

    /// Feeds `bytes` and acts on the keys found, as the app does. Returns
    /// the bytes passed on, which the caller owns.
    fn type_(self: *Sim, gpa: std.mem.Allocator, bytes: []const u8) !std.ArrayList(u8) {
        var passed: std.ArrayList(u8) = .empty;
        errdefer passed.deinit(gpa);
        var buf: Matcher.Buffer = undefined;
        for (bytes) |byte| {
            const result = self.view.matcher.feed(self.view.keys(), byte, self.now_ms, &buf);
            try passed.appendSlice(gpa, result.pass);
            if (result.key) |key| self.act(key);
        }
        self.now_ms += escape_timeout_ms;
        const result = self.view.matcher.expire(self.view.keys(), self.now_ms, &buf);
        try passed.appendSlice(gpa, result.pass);
        if (result.key) |key| self.act(key);
        return passed;
    }

    fn act(self: *Sim, key: Key) void {
        switch (self.view.mode) {
            .main => unreachable,
            .picker => switch (key) {
                .up, .down => self.view.move(key, children),
                .enter => if (self.alive[self.view.selected]) self.view.choose(@intCast(self.view.selected + 1)),
                .escape, .ctrl_t => self.leave(),
            },
            .view => switch (key) {
                .ctrl_t => self.leave(),
                else => unreachable,
            },
        }
    }
};

const SimAction = enum { CtrlTOnMain, PickerKey, GoBack, Key, ChildExits, PromptOpens, PromptShows, PromptCloses, Tick, MainPaints };

const Choices = struct {
    items: [@typeInfo(SimAction).@"enum".fields.len]SimAction = undefined,
    len: usize = 0,

    fn add(self: *Choices, enabled: bool, action: SimAction) void {
        if (!enabled) return;
        self.items[self.len] = action;
        self.len += 1;
    }
};

const ctrl_t_forms = [_][]const u8{ "\x14", "\x1b[116;5u", "\x1b[27;5;116~" };
const child_keys = [_][]const u8{ "a", "\r", "\x1b[A", "\x1b", "\x1b[1;5C", "\x1b[200~hi\x1b[201~" };

fn runView(gpa: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var sim: Sim = .{};

    var steps: usize = 0;
    while (steps < 80) : (steps += 1) {
        const mode = sim.view.mode;
        const viewed_gone = if (sim.view.viewed) |c| !sim.alive[c - 1] else false;
        var choices: Choices = .{};
        choices.add(mode == .main, .CtrlTOnMain);
        choices.add(mode == .picker, .PickerKey);
        choices.add(mode != .main, .GoBack);
        choices.add(mode != .picker, .Key);
        choices.add(sim.alive[0] or sim.alive[1], .ChildExits);
        choices.add(!sim.prompt, .PromptOpens);
        choices.add(sim.prompt and sim.owner == .none, .PromptShows);
        choices.add(sim.prompt, .PromptCloses);
        choices.add(sim.view.mustLeave(viewed_gone), .Tick);
        choices.add(mode == .main and sim.owner == .none, .MainPaints);

        const action = choices.items[random.uintLessThan(usize, choices.len)];
        switch (action) {
            .CtrlTOnMain => {
                // Main decodes Ctrl+T itself; a prompt on screen takes it.
                if (sim.owner == .none and sim.view.open(sim.prompt)) {
                    sim.owner = .view;
                    sim.main_screen = .stale;
                } else {
                    sim.key_to = "main";
                }
            },
            .PickerKey => {
                const keys_ = [_][]const u8{ "\x1b[A", "\x1bOA", "\x1b[B", "\x1bOB", "\r", "\x1b[13u" };
                var passed = try sim.type_(gpa, keys_[random.uintLessThan(usize, keys_.len)]);
                defer passed.deinit(gpa);
                try testing.expectEqual(@as(usize, 0), passed.items.len);
                if (sim.view.mode == .view) {} else {
                    sim.key_to = "picker";
                }
            },
            .GoBack => {
                const back = if (mode == .picker and random.boolean())
                    (if (random.boolean()) "\x1b[27u" else "\x1b")
                else
                    ctrl_t_forms[random.uintLessThan(usize, ctrl_t_forms.len)];
                var passed = try sim.type_(gpa, back);
                defer passed.deinit(gpa);
                try testing.expectEqual(@as(usize, 0), passed.items.len);
                try testing.expectEqual(Mode.main, sim.view.mode);
            },
            .Key => if (mode == .view) {
                const typed = child_keys[random.uintLessThan(usize, child_keys.len)];
                var passed = try sim.type_(gpa, typed);
                defer passed.deinit(gpa);
                try testing.expectEqualStrings(typed, passed.items);
                try testing.expectEqual(Mode.view, sim.view.mode);
                sim.key_to = "child";
            } else {
                sim.key_to = "main";
            },
            .ChildExits => {
                const c = if (!sim.alive[0]) 1 else if (!sim.alive[1]) 0 else random.uintLessThan(usize, 2);
                sim.alive[c] = false;
            },
            .PromptOpens => sim.prompt = true,
            .PromptShows => {
                sim.owner = .prompt;
                sim.main_screen = .stale;
            },
            .PromptCloses => {
                sim.prompt = false;
                if (sim.owner == .prompt) {
                    sim.owner = .none;
                    sim.redraw = true;
                }
            },
            .Tick => sim.leave(),
            .MainPaints => {
                if (sim.redraw) sim.main_screen = .current;
                sim.redraw = false;
            },
        }
    }
}

test "random runs keep the view's rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runView(testing.allocator, seed);
}
