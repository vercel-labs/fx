//! Compiles hook matchers and tests values against them. A matcher is a name
//! list such as `Edit|Write`, a regular expression, or `*` for every value.

const std = @import("std");
const limits = @import("limits.zig");

/// Errors from compiling a matcher.
const CompileError = std.mem.Allocator.Error || error{ InvalidMatcher, MatcherTooLong };

/// The most instructions one compiled program may hold.
const max_program = 4096;

/// The deepest group nesting a pattern may use.
const max_group_depth = 32;

/// One set of bytes, as stored by a character class.
const ClassSet = std.bit_set.Static(256);

/// One instruction of a compiled program. All addresses are instruction indexes.
const Inst = union(enum) {
    byte: u8,
    any,
    class: u16,
    split: struct { a: u16, b: u16 },
    jmp: u16,
    match,
    assert_start,
    assert_end,
};

/// A compiled matcher. Owns its memory; free it with deinit.
pub const Matcher = struct {
    kind: Kind,
    /// Owned copies of the names of a name list.
    names: [][]u8 = &.{},
    /// Owned program of a regular expression.
    program: []Inst = &.{},
    /// Owned classes of a regular expression.
    classes: []ClassSet = &.{},

    const Kind = enum { all, names, regex };

    pub fn deinit(self: *Matcher, alloc: std.mem.Allocator) void {
        for (self.names) |name| alloc.free(name);
        if (self.names.len > 0) alloc.free(self.names);
        if (self.program.len > 0) alloc.free(self.program);
        if (self.classes.len > 0) alloc.free(self.classes);
        self.* = undefined;
    }

    /// Whether `value` matches. Allocates nothing; safe to call from many threads at once.
    pub fn matches(self: *const Matcher, value: []const u8) bool {
        switch (self.kind) {
            .all => return true,
            .names => {
                for (self.names) |name| {
                    if (std.mem.eql(u8, name, value)) return true;
                }
                return false;
            },
            .regex => {},
        }

        var current: List = .{ .states = undefined, .count = 0, .seen = std.bit_set.Static(max_program).empty };
        var next: List = current;
        var stack: [max_program]u16 = undefined;

        var pos: usize = 0;
        while (true) {
            addState(self.program, &current, &stack, 0, pos, value.len);
            for (current.states[0..current.count]) |pc| {
                switch (self.program[pc]) {
                    .match => return true,
                    else => {},
                }
            }
            if (pos == value.len) return false;

            next.count = 0;
            next.seen = std.bit_set.Static(max_program).empty;
            const byte = value[pos];
            for (current.states[0..current.count]) |pc| {
                const takes = switch (self.program[pc]) {
                    .byte => |wanted| wanted == byte,
                    .any => true,
                    .class => |class_index| self.classes[class_index].isSet(byte),
                    else => false,
                };
                if (takes) addState(self.program, &next, &stack, pc + 1, pos + 1, value.len);
            }

            const held = current;
            current = next;
            next = held;
            pos += 1;
        }
    }

    /// For tool events: whether the fx tool name, or one of its Claude Code names, matches.
    pub fn matchesTool(self: *const Matcher, fx_name: []const u8) bool {
        if (self.matches(fx_name)) return true;
        for (claudeNames(fx_name)) |name| {
            if (self.matches(name)) return true;
        }
        return false;
    }
};

/// One list of Pike VM states and the set that keeps each state out of it twice.
const List = struct {
    states: [max_program]u16,
    count: usize,
    seen: std.bit_set.Static(max_program),
};

/// Adds `start` and every state reachable from it through empty instructions.
/// `pos` decides the two anchors. Nothing is allocated.
fn addState(
    program: []const Inst,
    list: *List,
    stack: *[max_program]u16,
    start: u16,
    pos: usize,
    len: usize,
) void {
    var top: usize = 1;
    stack[0] = start;
    while (top > 0) {
        top -= 1;
        var pc = stack[top];
        while (true) {
            if (list.seen.isSet(pc)) break;
            list.seen.set(pc);
            switch (program[pc]) {
                .jmp => |target| pc = target,
                .split => |split| {
                    if (!list.seen.isSet(split.b)) {
                        stack[top] = split.b;
                        top += 1;
                    }
                    if (list.seen.isSet(split.a)) break;
                    pc = split.a;
                },
                .assert_start => {
                    if (pos != 0) break;
                    pc += 1;
                },
                .assert_end => {
                    if (pos != len) break;
                    pc += 1;
                },
                else => {
                    list.states[list.count] = pc;
                    list.count += 1;
                    break;
                },
            }
        }
    }
}

/// Compiles `pattern`. The caller owns the result.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Matcher {
    if (pattern.len > limits.matcher_bytes) return error.MatcherTooLong;
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "*")) return .{ .kind = .all };
    if (isNameList(pattern)) return compileNames(alloc, pattern);
    return compileRegex(alloc, pattern);
}

/// Whether every byte of the pattern belongs to a name list.
fn isNameList(pattern: []const u8) bool {
    for (pattern) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '|' => {},
            else => return false,
        }
    }
    return true;
}

/// Compiles a pattern of names separated by `|`, skipping empty parts.
fn compileNames(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Matcher {
    var parts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (parts.items) |part| alloc.free(part);
        parts.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, pattern, '|');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const copy = try alloc.dupe(u8, part);
        errdefer alloc.free(copy);
        try parts.append(alloc, copy);
    }
    if (parts.items.len == 0) return error.InvalidMatcher;

    return .{ .kind = .names, .names = try parts.toOwnedSlice(alloc) };
}

/// The Claude Code names of an fx tool, or an empty slice.
fn claudeNames(fx_name: []const u8) []const []const u8 {
    const table = [_]struct { fx: []const u8, names: []const []const u8 }{
        .{ .fx = "shell", .names = &.{"Bash"} },
        .{ .fx = "read_file", .names = &.{"Read"} },
        .{ .fx = "write_file", .names = &.{"Write"} },
        .{ .fx = "edit_file", .names = &.{ "Edit", "MultiEdit" } },
        .{ .fx = "glob_files", .names = &.{"Glob"} },
        .{ .fx = "grep_files", .names = &.{"Grep"} },
        .{ .fx = "web_fetch", .names = &.{"WebFetch"} },
        .{ .fx = "web_search", .names = &.{"WebSearch"} },
        .{ .fx = "subagent", .names = &.{ "Task", "Agent" } },
        .{ .fx = "ask_user_question", .names = &.{"AskUserQuestion"} },
        .{ .fx = "skill", .names = &.{"Skill"} },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.fx, fx_name)) return entry.names;
    }
    return &.{};
}

/// One parsed node of a regular expression.
const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: u16,
    assert_start,
    assert_end,
    /// Two or more alternatives.
    alt: []*Node,
    /// A sequence, possibly empty.
    concat: []*Node,
    repeat: struct { node: *Node, kind: RepeatKind },
};

const RepeatKind = enum { star, plus, optional };

/// One item read inside a character class.
const ClassItem = union(enum) { byte: u8, set: ClassSet };

/// Parses a pattern into a tree. All nodes come from the arena the caller passes.
const Parser = struct {
    alloc: std.mem.Allocator,
    pattern: []const u8,
    index: usize = 0,
    depth: usize = 0,
    classes: std.ArrayList(ClassSet) = .empty,

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.pattern.len) return null;
        return self.pattern[self.index];
    }

    fn node(self: *Parser, value: Node) CompileError!*Node {
        const created = try self.alloc.create(Node);
        created.* = value;
        return created;
    }

    fn parseAlt(self: *Parser) CompileError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.alloc, try self.parseConcat());
        while (self.peek() == '|') {
            self.index += 1;
            try branches.append(self.alloc, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alt = try branches.toOwnedSlice(self.alloc) });
    }

    fn parseConcat(self: *Parser) CompileError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (self.index < self.pattern.len) {
            const c = self.pattern[self.index];
            if (c == '|' or c == ')') break;
            try items.append(self.alloc, try self.parseRepeat());
        }
        if (items.items.len == 0) return self.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.node(.{ .concat = try items.toOwnedSlice(self.alloc) });
    }

    fn parseRepeat(self: *Parser) CompileError!*Node {
        const atom = try self.parseAtom();
        const kind: RepeatKind = switch (self.peek() orelse return atom) {
            '*' => .star,
            '+' => .plus,
            '?' => .optional,
            else => return atom,
        };
        self.index += 1;
        if (self.peek()) |lazy| {
            if (lazy == '?') self.index += 1;
        }
        if (self.peek()) |again| {
            if (again == '*' or again == '+' or again == '?') return error.InvalidMatcher;
        }
        return self.node(.{ .repeat = .{ .node = atom, .kind = kind } });
    }

    fn parseAtom(self: *Parser) CompileError!*Node {
        const c = self.peek() orelse return error.InvalidMatcher;
        switch (c) {
            '.' => {
                self.index += 1;
                return self.node(.any);
            },
            '^' => {
                self.index += 1;
                return self.node(.assert_start);
            },
            '$' => {
                self.index += 1;
                return self.node(.assert_end);
            },
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '\\' => return self.parseEscape(),
            '*', '+', '?', '|', ')', '{', '}' => return error.InvalidMatcher,
            else => {
                self.index += 1;
                return self.node(.{ .literal = c });
            },
        }
    }

    fn parseGroup(self: *Parser) CompileError!*Node {
        self.index += 1; // past '('
        if (self.peek() == '?') {
            if (self.index + 1 >= self.pattern.len or self.pattern[self.index + 1] != ':') return error.InvalidMatcher;
            self.index += 2;
        }
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_group_depth) return error.InvalidMatcher;

        const inner = try self.parseAlt();
        const closing = self.peek() orelse return error.InvalidMatcher;
        if (closing != ')') return error.InvalidMatcher;
        self.index += 1;
        return inner;
    }

    fn parseEscape(self: *Parser) CompileError!*Node {
        return switch (try self.readEscape()) {
            .byte => |b| self.node(.{ .literal = b }),
            .set => |set| self.classNode(set),
        };
    }

    fn classNode(self: *Parser, set: ClassSet) CompileError!*Node {
        const index: u16 = @intCast(self.classes.items.len);
        try self.classes.append(self.alloc, set);
        return self.node(.{ .class = index });
    }

    /// Reads one escape sequence and returns the byte or the set it stands for. An escaped letter or
    /// digit other than the classes above is invalid, so `\b`, `\n`, and `\1` never match as letters.
    fn readEscape(self: *Parser) CompileError!ClassItem {
        if (self.index + 1 >= self.pattern.len) return error.InvalidMatcher;
        const c = self.pattern[self.index + 1];
        self.index += 2;
        return switch (c) {
            'd' => .{ .set = digitSet() },
            'w' => .{ .set = wordSet() },
            's' => .{ .set = spaceSet() },
            'D' => .{ .set = complement(digitSet()) },
            'W' => .{ .set = complement(wordSet()) },
            'S' => .{ .set = complement(spaceSet()) },
            else => blk: {
                if (std.ascii.isAlphanumeric(c)) return error.InvalidMatcher;
                break :blk .{ .byte = c };
            },
        };
    }

    fn parseClass(self: *Parser) CompileError!*Node {
        self.index += 1; // past '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.index += 1;
        }

        var set = ClassSet.empty;
        var first = true;
        var closed = false;
        while (self.index < self.pattern.len) {
            const c = self.pattern[self.index];
            if (c == ']' and !first) {
                self.index += 1;
                closed = true;
                break;
            }
            first = false;

            switch (try self.classItem()) {
                .set => |extra| mergeSet(&set, extra),
                .byte => |low| {
                    if (self.isRangeStart()) {
                        self.index += 1; // past '-'
                        const high = switch (try self.classItem()) {
                            .byte => |b| b,
                            .set => return error.InvalidMatcher,
                        };
                        if (low > high) return error.InvalidMatcher;
                        addRange(&set, low, high);
                    } else {
                        set.set(low);
                    }
                },
            }
        }
        if (!closed) return error.InvalidMatcher;
        if (negated) set.toggleAll();
        return self.classNode(set);
    }

    /// Whether the next bytes start a range, as in `a-z`; a `-` before `]` is literal.
    fn isRangeStart(self: *const Parser) bool {
        if (self.peek() != '-') return false;
        if (self.index + 1 >= self.pattern.len) return false;
        return self.pattern[self.index + 1] != ']';
    }

    fn classItem(self: *Parser) CompileError!ClassItem {
        const c = self.peek() orelse return error.InvalidMatcher;
        if (c == '\\') return self.readEscape();
        self.index += 1;
        return .{ .byte = c };
    }
};

/// Turns a parsed tree into a program, patching every forward address afterwards.
const Emitter = struct {
    alloc: std.mem.Allocator,
    program: std.ArrayList(Inst) = .empty,

    fn here(self: *const Emitter) u16 {
        return @intCast(self.program.items.len);
    }

    fn append(self: *Emitter, inst: Inst) CompileError!u16 {
        if (self.program.items.len >= max_program) return error.MatcherTooLong;
        const at = self.here();
        try self.program.append(self.alloc, inst);
        return at;
    }

    fn emit(self: *Emitter, node: *const Node) CompileError!void {
        switch (node.*) {
            .empty => {},
            .literal => |b| _ = try self.append(.{ .byte = b }),
            .any => _ = try self.append(.any),
            .class => |index| _ = try self.append(.{ .class = index }),
            .assert_start => _ = try self.append(.assert_start),
            .assert_end => _ = try self.append(.assert_end),
            .concat => |items| for (items) |item| try self.emit(item),
            .alt => |branches| try self.emitAlt(branches),
            .repeat => |rep| try self.emitRepeat(rep.node, rep.kind),
        }
    }

    fn emitAlt(self: *Emitter, branches: []const *Node) CompileError!void {
        const split_at = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
        const left = self.here();
        try self.emit(branches[0]);
        const jump_at = try self.append(.{ .jmp = 0 });
        const right = self.here();
        if (branches.len == 2) {
            try self.emit(branches[1]);
        } else {
            try self.emitAlt(branches[1..]);
        }
        const end = self.here();
        self.program.items[split_at] = .{ .split = .{ .a = left, .b = right } };
        self.program.items[jump_at] = .{ .jmp = end };
    }

    fn emitRepeat(self: *Emitter, inner: *const Node, kind: RepeatKind) CompileError!void {
        switch (kind) {
            .star => {
                const split_at = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                const body = self.here();
                try self.emit(inner);
                _ = try self.append(.{ .jmp = split_at });
                const end = self.here();
                self.program.items[split_at] = .{ .split = .{ .a = body, .b = end } };
            },
            .plus => {
                const body = self.here();
                try self.emit(inner);
                const split_at = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                const end = self.here();
                self.program.items[split_at] = .{ .split = .{ .a = body, .b = end } };
            },
            .optional => {
                const split_at = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                const body = self.here();
                try self.emit(inner);
                const end = self.here();
                self.program.items[split_at] = .{ .split = .{ .a = body, .b = end } };
            },
        }
    }
};

/// Compiles a pattern that is a regular expression.
fn compileRegex(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Matcher {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser: Parser = .{ .alloc = arena, .pattern = pattern };
    const tree = try parser.parseAlt();
    if (parser.index != pattern.len) return error.InvalidMatcher;

    var emitter: Emitter = .{ .alloc = alloc };
    errdefer emitter.program.deinit(alloc);
    try emitter.emit(tree);
    _ = try emitter.append(.match);

    const classes = try alloc.dupe(ClassSet, parser.classes.items);
    errdefer alloc.free(classes);
    const program = try emitter.program.toOwnedSlice(alloc);

    return .{ .kind = .regex, .program = program, .classes = classes };
}

/// Adds every byte from `low` to `high` to the set.
fn addRange(set: *ClassSet, low: u8, high: u8) void {
    var index: usize = low;
    const last: usize = high;
    while (index <= last) : (index += 1) set.set(index);
}

/// Adds every byte of `extra` to `target`.
fn mergeSet(target: *ClassSet, extra: ClassSet) void {
    const byte_values = std.math.maxInt(u8) + 1;
    var index: usize = 0;
    while (index < byte_values) : (index += 1) {
        if (extra.isSet(index)) target.set(index);
    }
}

fn digitSet() ClassSet {
    var set = ClassSet.empty;
    addRange(&set, '0', '9');
    return set;
}

fn wordSet() ClassSet {
    var set = ClassSet.empty;
    addRange(&set, '0', '9');
    addRange(&set, 'A', 'Z');
    addRange(&set, 'a', 'z');
    set.set('_');
    return set;
}

fn spaceSet() ClassSet {
    var set = ClassSet.empty;
    set.set(' ');
    set.set('\t');
    set.set('\n');
    set.set('\r');
    set.set(0x0b);
    set.set(0x0c);
    return set;
}

fn complement(set: ClassSet) ClassSet {
    var flipped = set;
    flipped.toggleAll();
    return flipped;
}

fn expectMatches(alloc: std.mem.Allocator, pattern: []const u8, value: []const u8, want: bool) !void {
    var matcher = try compile(alloc, pattern);
    defer matcher.deinit(alloc);
    try std.testing.expectEqual(want, matcher.matches(value));
}

fn expectTool(alloc: std.mem.Allocator, pattern: []const u8, fx_name: []const u8, want: bool) !void {
    var matcher = try compile(alloc, pattern);
    defer matcher.deinit(alloc);
    try std.testing.expectEqual(want, matcher.matchesTool(fx_name));
}

fn expectInvalid(alloc: std.mem.Allocator, pattern: []const u8) !void {
    if (compile(alloc, pattern)) |value| {
        var matcher = value;
        matcher.deinit(alloc);
        return error.ExpectedInvalidMatcher;
    } else |err| {
        try std.testing.expect(err == error.InvalidMatcher);
    }
}

test "an empty pattern and a star match every value" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "", "Bash", true);
    try expectMatches(alloc, "", "", true);
    try expectMatches(alloc, "*", "anything", true);
    try expectMatches(alloc, "*", "", true);
}

test "a name list matches whole names" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "Bash", "Bash", true);
    try expectMatches(alloc, "Bash", "BashOutput", false);
    try expectMatches(alloc, "Bash", "bash", false);
    try expectMatches(alloc, "Bash", "", false);
    try expectMatches(alloc, "Edit|Write", "Edit", true);
    try expectMatches(alloc, "Edit|Write", "Write", true);
    try expectMatches(alloc, "Edit|Write", "Read", false);
    try expectMatches(alloc, "Edit||Write", "Edit", true);
    try expectMatches(alloc, "Edit||Write", "Write", true);
    try expectInvalid(alloc, "|");
    try expectInvalid(alloc, "||");
}

test "a regex can match a prefix" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "mcp__github__.*", "mcp__github__create_issue", true);
    try expectMatches(alloc, "mcp__github__.*", "mcp__gitlab__list", false);
}

test "a regex is searched anywhere in the value" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "a.c", "xxabcxx", true);
    try expectMatches(alloc, "^mcp__", "mcp__a__b", true);
    try expectMatches(alloc, "^mcp__", "x_mcp__a", false);
    try expectMatches(alloc, "_file$", "edit_file", true);
    try expectMatches(alloc, "_file$", "edit_file2", false);
}

test "quantifiers repeat the atom before them" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "colou?r", "color", true);
    try expectMatches(alloc, "colou?r", "colour", true);
    try expectMatches(alloc, "ab+c", "abbc", true);
    try expectMatches(alloc, "ab+c", "ac", false);
    try expectMatches(alloc, "ab*c", "ac", true);
    try expectMatches(alloc, "a*?b", "aab", true);
}

test "groups and alternation" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "(Edit|Write)$", "MultiEdit", true);
    try expectMatches(alloc, "(Edit|Write)$", "Editor", false);
    try expectMatches(alloc, "(?:Read|Grep)", "Grep", true);
    try expectMatches(alloc, "x(a|b)*y", "xababy", true);
    try expectMatches(alloc, "x(a|b)*y", "xy", true);
    try expectMatches(alloc, "x(a|b)*y", "xcy", false);
}

test "classes and escapes" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "[a-c]x", "bx", true);
    try expectMatches(alloc, "[a-c]x", "dx", false);
    try expectMatches(alloc, "[^a]b", "cb", true);
    try expectMatches(alloc, "[^a]b", "ab", false);
    try expectMatches(alloc, "[]a]", "]", true);
    try expectMatches(alloc, "[a-]", "-", true);
    try expectMatches(alloc, "\\d+", "abc123", true);
    try expectMatches(alloc, "\\d+", "abc", false);
    try expectMatches(alloc, "\\w\\s\\W", "a !", true);
    try expectMatches(alloc, "a\\.b", "a.b", true);
    try expectMatches(alloc, "a\\.b", "axb", false);
    try expectMatches(alloc, "a\\{2\\}", "a{2}", true);
}

test "escaped punctuation is literal, and a letter, digit, or brace that is not escaped as a class is invalid" {
    const alloc = std.testing.allocator;
    try expectMatches(alloc, "a\\|b", "a|b", true);
    try expectMatches(alloc, "a\\(b\\)", "a(b)", true);
    try expectMatches(alloc, "a\\\\b", "a\\b", true);
    try expectMatches(alloc, "a\\/b", "a/b", true);
    try expectMatches(alloc, "a\\-b", "a-b", true);
    try expectMatches(alloc, "\\d+", "x42", true);
    try expectInvalid(alloc, "\\b");
    try expectInvalid(alloc, "\\B");
    try expectInvalid(alloc, "\\n");
    try expectInvalid(alloc, "\\t");
    try expectInvalid(alloc, "\\1");
    try expectInvalid(alloc, "a{2}");
    try expectInvalid(alloc, "a{");
    try expectInvalid(alloc, "}");
    try expectInvalid(alloc, "[\\b]");
}

test "an invalid pattern is rejected" {
    const alloc = std.testing.allocator;
    try expectInvalid(alloc, "(");
    try expectInvalid(alloc, ")");
    try expectInvalid(alloc, "(a");
    try expectInvalid(alloc, "[a");
    try expectInvalid(alloc, "*a");
    try expectInvalid(alloc, "a|*");
    try expectInvalid(alloc, "a**");
    try expectInvalid(alloc, "a+*");
    try expectInvalid(alloc, "\\");
    try expectInvalid(alloc, "[z-a]");
    try expectInvalid(alloc, "(?=a)");
}

test "group nesting is capped" {
    const alloc = std.testing.allocator;

    var deep: [67]u8 = undefined;
    @memset(deep[0..33], '(');
    deep[33] = 'a';
    @memset(deep[34..], ')');
    try expectInvalid(alloc, &deep);

    var allowed: [65]u8 = undefined;
    @memset(allowed[0..32], '(');
    allowed[32] = 'a';
    @memset(allowed[33..], ')');
    var matcher = try compile(alloc, &allowed);
    defer matcher.deinit(alloc);
    try std.testing.expect(matcher.matches("a"));
}

test "a pattern longer than the matcher limit is rejected" {
    const alloc = std.testing.allocator;
    const long = try alloc.alloc(u8, limits.matcher_bytes + 1);
    defer alloc.free(long);
    @memset(long, 'a');

    if (compile(alloc, long)) |value| {
        var matcher = value;
        matcher.deinit(alloc);
        return error.ExpectedMatcherTooLong;
    } else |err| {
        try std.testing.expect(err == error.MatcherTooLong);
    }
}

test "a star of a star does not blow up" {
    const alloc = std.testing.allocator;
    const value = try alloc.alloc(u8, 4000);
    defer alloc.free(value);
    @memset(value, 'a');

    var matcher = try compile(alloc, "(a*)*b");
    defer matcher.deinit(alloc);
    try std.testing.expect(!matcher.matches(value));
}

test "tool names match through their Claude Code names" {
    const alloc = std.testing.allocator;
    try expectTool(alloc, "Bash", "shell", true);
    try expectTool(alloc, "Edit|Write", "edit_file", true);
    try expectTool(alloc, "Edit|Write", "write_file", true);
    try expectTool(alloc, "MultiEdit", "edit_file", true);
    try expectTool(alloc, "shell", "shell", true);
    try expectTool(alloc, "mcp__.*", "mcp__server__tool", true);
    try expectTool(alloc, "Task", "subagent", true);
    try expectTool(alloc, "Agent", "subagent", true);
    try expectTool(alloc, "Bash", "read_file", false);
}

test "the Claude Code names of a tool" {
    try std.testing.expectEqual(@as(usize, 0), claudeNames("unknown").len);
    try std.testing.expectEqual(@as(usize, 2), claudeNames("edit_file").len);
}
