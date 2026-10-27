//! A small backtracking regular expression engine for rule conditions.
//!
//! Rules are written for JavaScript's `RegExp`, so this engine reads that
//! dialect: literals, `.`, classes with ranges and the `\d \w \s` escapes and
//! their negations, anchors `^ $ \b \B`, groups `( )` `(?: )` `(?<name> )`,
//! lookahead `(?= )` `(?! )`, lookbehind `(?<= )` `(?<! )`, alternation,
//! and the greedy and lazy quantifiers `* + ? {n} {n,} {n,m}`. A leading
//! `(?ims)` sets the flags, as proto's `compileRuleCondition` does.
//!
//! It works on bytes: `.` and negated classes match one byte, so a match
//! offset is a byte offset into the buffer. Backreferences are refused at
//! compile time. Matching is bounded by a step budget, and a search that
//! spends it reports no match rather than stalling the stream.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Flags = struct {
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
};

pub const Error = error{ InvalidPattern, OutOfMemory };

const ByteSet = std.bit_set.Static(256);

const Repeat = struct {
    body: []const Node,
    min: u32,
    max: u32,
    greedy: bool,
    /// The body is one node that always consumes exactly one byte.
    single: ?ByteSet,
};

const Look = struct {
    alts: []const []const Node,
    ahead: bool,
    negate: bool,
};

const Node = union(enum) {
    set: ByteSet,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    group: []const []const Node,
    repeat: Repeat,
    look: Look,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    alts: []const []const Node,
    flags: Flags,
    source: []const u8,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// The first match at or after `from`, as a byte span, or null.
    pub fn find(self: *const Regex, text: []const u8, from: usize) ?Span {
        var start = from;
        while (start <= text.len) : (start += 1) {
            var m: Matcher = .{ .text = text, .flags = self.flags };
            if (m.alternatives(self.alts, start, null)) return .{ .start = start, .end = m.end };
            if (m.exhausted) return null;
        }
        return null;
    }

    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        return self.find(text, 0) != null;
    }
};

pub const Span = struct { start: usize, end: usize };

/// Compiles `source`. A leading `(?flags)` group of `i`, `m` and `s` sets
/// the flags; any other leading flag group is invalid.
pub fn compile(gpa: Allocator, source: []const u8) Error!Regex {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var flags: Flags = .{};
    var body = source;
    if (std.mem.startsWith(u8, body, "(?")) {
        var index: usize = 2;
        while (index < body.len and std.ascii.isLower(body[index])) index += 1;
        if (index > 2 and index < body.len and body[index] == ')') {
            for (body[2..index]) |flag| switch (flag) {
                'i' => flags.ignore_case = true,
                'm' => flags.multiline = true,
                's' => flags.dot_all = true,
                else => return error.InvalidPattern,
            };
            body = body[index + 1 ..];
        }
    }
    var parser: Parser = .{ .alloc = alloc, .src = body, .flags = flags };
    const alts = try parser.alternation();
    if (parser.pos != body.len) return error.InvalidPattern;
    return .{ .arena = arena, .alts = alts, .flags = flags, .source = try alloc.dupe(u8, source) };
}

const Parser = struct {
    alloc: Allocator,
    src: []const u8,
    pos: usize = 0,
    flags: Flags,
    depth: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn alternation(self: *Parser) Error![]const []const Node {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64) return error.InvalidPattern;
        var alts: std.ArrayList([]const Node) = .empty;
        while (true) {
            try alts.append(self.alloc, try self.sequence());
            if (self.peek() == '|') {
                self.pos += 1;
                continue;
            }
            break;
        }
        return alts.toOwnedSlice(self.alloc);
    }

    fn sequence(self: *Parser) Error![]const Node {
        var nodes: std.ArrayList(Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            const parsed = try self.atom();
            const quantified = try self.quantifier(parsed);
            try nodes.append(self.alloc, quantified);
        }
        return nodes.toOwnedSlice(self.alloc);
    }

    fn quantifier(self: *Parser, item: Node) Error!Node {
        const c = self.peek() orelse return item;
        var min: u32 = 0;
        var max: u32 = std.math.maxInt(u32);
        switch (c) {
            '*' => self.pos += 1,
            '+' => {
                min = 1;
                self.pos += 1;
            },
            '?' => {
                max = 1;
                self.pos += 1;
            },
            '{' => {
                const save = self.pos;
                self.pos += 1;
                const lo = self.number() orelse {
                    self.pos = save;
                    return item;
                };
                min = lo;
                max = lo;
                if (self.peek() == ',') {
                    self.pos += 1;
                    max = self.number() orelse std.math.maxInt(u32);
                }
                if (self.peek() != '}') {
                    // A brace that is not a quantifier is a literal, as in JS.
                    self.pos = save;
                    return item;
                }
                self.pos += 1;
                if (max < min) return error.InvalidPattern;
            },
            else => return item,
        }
        switch (item) {
            .bol, .eol, .word_boundary, .not_word_boundary, .look => return error.InvalidPattern,
            .repeat => return error.InvalidPattern,
            else => {},
        }
        var greedy = true;
        if (self.peek() == '?') {
            greedy = false;
            self.pos += 1;
        }
        const body = try self.alloc.alloc(Node, 1);
        body[0] = item;
        return .{ .repeat = .{
            .body = body,
            .min = min,
            .max = max,
            .greedy = greedy,
            .single = if (item == .set) item.set else null,
        } };
    }

    fn number(self: *Parser) ?u32 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch null;
    }

    fn atom(self: *Parser) Error!Node {
        const c = self.src[self.pos];
        self.pos += 1;
        switch (c) {
            '.' => {
                var set = ByteSet.full;
                if (!self.flags.dot_all) {
                    set.unset('\n');
                    set.unset('\r');
                }
                return .{ .set = set };
            },
            '^' => return .bol,
            '$' => return .eol,
            '[' => return .{ .set = try self.class() },
            '(' => return self.group(),
            '\\' => return self.escape(false),
            '*', '+', '?' => return error.InvalidPattern,
            else => return .{ .set = self.literal(c) },
        }
    }

    fn literal(self: *const Parser, c: u8) ByteSet {
        var set = ByteSet.empty;
        set.set(c);
        if (self.flags.ignore_case and std.ascii.isAlphabetic(c)) {
            set.set(std.ascii.toLower(c));
            set.set(std.ascii.toUpper(c));
        }
        return set;
    }

    fn group(self: *Parser) Error!Node {
        var look: ?struct { ahead: bool, negate: bool } = null;
        if (self.peek() == '?') {
            self.pos += 1;
            const kind = self.peek() orelse return error.InvalidPattern;
            switch (kind) {
                ':' => self.pos += 1,
                '=' => {
                    self.pos += 1;
                    look = .{ .ahead = true, .negate = false };
                },
                '!' => {
                    self.pos += 1;
                    look = .{ .ahead = true, .negate = true };
                },
                '<' => {
                    self.pos += 1;
                    const next = self.peek() orelse return error.InvalidPattern;
                    if (next == '=' or next == '!') {
                        self.pos += 1;
                        look = .{ .ahead = false, .negate = next == '!' };
                    } else {
                        // A named group: the name is not kept.
                        while (self.peek()) |name_byte| {
                            self.pos += 1;
                            if (name_byte == '>') break;
                            if (!std.ascii.isAlphanumeric(name_byte) and name_byte != '_' and name_byte != '$') return error.InvalidPattern;
                        } else return error.InvalidPattern;
                    }
                },
                else => return error.InvalidPattern,
            }
        }
        const alts = try self.alternation();
        if (self.peek() != ')') return error.InvalidPattern;
        self.pos += 1;
        if (look) |kind| return .{ .look = .{ .alts = alts, .ahead = kind.ahead, .negate = kind.negate } };
        return .{ .group = alts };
    }

    fn escape(self: *Parser, in_class: bool) Error!Node {
        const c = self.peek() orelse return error.InvalidPattern;
        self.pos += 1;
        var set = ByteSet.empty;
        switch (c) {
            'd', 'D' => setRange(&set, '0', '9'),
            'w', 'W' => addWord(&set),
            's', 'S' => for (" \t\n\r\x0b\x0c") |space| set.set(space),
            'b' => {
                if (in_class) {
                    set.set(0x08);
                    return .{ .set = set };
                }
                return .word_boundary;
            },
            'B' => {
                if (in_class) return error.InvalidPattern;
                return .not_word_boundary;
            },
            'n' => set.set('\n'),
            'r' => set.set('\r'),
            't' => set.set('\t'),
            'f' => set.set(0x0c),
            'v' => set.set(0x0b),
            '0' => set.set(0),
            'x' => {
                const value = self.hexDigits(2) orelse return error.InvalidPattern;
                set.set(@intCast(value));
            },
            'u' => {
                const value = self.hexDigits(4) orelse return error.InvalidPattern;
                if (value > 0x7f) return error.InvalidPattern;
                set.set(@intCast(value));
            },
            '1'...'9' => return error.InvalidPattern,
            else => {
                if (std.ascii.isAlphanumeric(c)) return error.InvalidPattern;
                return .{ .set = self.literal(c) };
            },
        }
        if (c == 'D' or c == 'W' or c == 'S') set.toggleAll();
        return .{ .set = set };
    }

    fn hexDigits(self: *Parser, count: usize) ?u32 {
        if (self.pos + count > self.src.len) return null;
        const value = std.fmt.parseInt(u32, self.src[self.pos .. self.pos + count], 16) catch return null;
        self.pos += count;
        return value;
    }

    fn class(self: *Parser) Error!ByteSet {
        var set = ByteSet.empty;
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.pos += 1;
        }
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern;
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            var low: ?u8 = null;
            if (c == '\\') {
                self.pos += 1;
                const escaped = try self.escape(true);
                const escaped_set = escaped.set;
                if (escaped_set.count() == 1 or (self.flags.ignore_case and escaped_set.count() == 2 and isCaseFoldPair(escaped_set))) {
                    low = @intCast(escaped_set.findFirstSet().?);
                } else {
                    set.setUnion(escaped_set);
                    continue;
                }
            } else {
                self.pos += 1;
                low = c;
            }
            const lo = low.?;
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1;
                var hi: u8 = self.src[self.pos];
                self.pos += 1;
                if (hi == '\\') {
                    const escaped = try self.escape(true);
                    if (escaped.set.count() != 1) return error.InvalidPattern;
                    hi = @intCast(escaped.set.findFirstSet().?);
                }
                if (hi < lo) return error.InvalidPattern;
                setRange(&set, lo, hi);
                if (self.flags.ignore_case) foldRange(&set, lo, hi);
            } else {
                set.setUnion(self.literal(lo));
            }
        }
        if (negate) set.toggleAll();
        return set;
    }
};

fn isCaseFoldPair(set: ByteSet) bool {
    const first: u8 = @intCast(set.findFirstSet() orelse return false);
    return std.ascii.isAlphabetic(first) and set.isSet(std.ascii.toLower(first)) and set.isSet(std.ascii.toUpper(first));
}

fn setRange(set: *ByteSet, lo: u8, hi: u8) void {
    var c: usize = lo;
    while (c <= hi) : (c += 1) set.set(c);
}

fn foldRange(set: *ByteSet, lo: u8, hi: u8) void {
    var c: usize = lo;
    while (c <= hi) : (c += 1) {
        const byte: u8 = @intCast(c);
        if (std.ascii.isAlphabetic(byte)) {
            set.set(std.ascii.toLower(byte));
            set.set(std.ascii.toUpper(byte));
        }
    }
}

fn addWord(set: *ByteSet) void {
    setRange(set, 'a', 'z');
    setRange(set, 'A', 'Z');
    setRange(set, '0', '9');
    set.set('_');
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Every attempt from one start position shares this budget.
const step_budget: usize = 200_000;
const max_depth: usize = 2_000;

const Cont = struct {
    kind: enum { seq, repeat, look_end },
    seq: []const Node = &.{},
    index: usize = 0,
    rep: ?*const Repeat = null,
    count: u32 = 0,
    iter_start: usize = 0,
    /// Lookbehind bodies must end exactly here.
    end_at: usize = 0,
    next: ?*const Cont,
};

const Matcher = struct {
    text: []const u8,
    flags: Flags,
    end: usize = 0,
    steps: usize = 0,
    depth: usize = 0,
    exhausted: bool = false,

    fn tick(self: *Matcher) bool {
        self.steps += 1;
        if (self.steps > step_budget or self.depth > max_depth) {
            self.exhausted = true;
            return false;
        }
        return true;
    }

    fn alternatives(self: *Matcher, alts: []const []const Node, pos: usize, k: ?*const Cont) bool {
        for (alts) |alt| {
            if (self.seqAt(alt, 0, pos, k)) return true;
            if (self.exhausted) return false;
        }
        return false;
    }

    fn resume_(self: *Matcher, k: ?*const Cont, pos: usize) bool {
        const cont = k orelse {
            self.end = pos;
            return true;
        };
        return switch (cont.kind) {
            .seq => self.seqAt(cont.seq, cont.index, pos, cont.next),
            .repeat => self.repeatAfter(cont.rep.?, cont.count, cont.iter_start, pos, cont.next),
            .look_end => pos == cont.end_at,
        };
    }

    fn seqAt(self: *Matcher, seq: []const Node, index: usize, pos: usize, k: ?*const Cont) bool {
        if (!self.tick()) return false;
        self.depth += 1;
        defer self.depth -= 1;
        var i = index;
        var p = pos;
        // Single-byte nodes and assertions advance without recursion.
        while (i < seq.len) : (i += 1) {
            switch (seq[i]) {
                .set => |set| {
                    if (p >= self.text.len or !set.isSet(self.text[p])) return false;
                    p += 1;
                },
                .bol => if (!self.atLineStart(p)) return false,
                .eol => if (!self.atLineEnd(p)) return false,
                .word_boundary => if (!self.atBoundary(p)) return false,
                .not_word_boundary => if (self.atBoundary(p)) return false,
                else => break,
            }
        }
        if (i == seq.len) return self.resume_(k, p);
        const after: Cont = .{ .kind = .seq, .seq = seq, .index = i + 1, .next = k };
        switch (seq[i]) {
            .group => |alts| return self.alternatives(alts, p, &after),
            .repeat => |*rep| {
                if (rep.single) |set| return self.repeatSingle(rep, set, p, &after);
                return self.repeatAfter(rep, 0, p, p, &after);
            },
            .look => |look| {
                if (!self.lookHolds(look, p)) return false;
                return self.seqAt(seq, i + 1, p, k);
            },
            else => unreachable,
        }
    }

    fn lookHolds(self: *Matcher, look: Look, pos: usize) bool {
        var probe: Matcher = .{ .text = self.text, .flags = self.flags, .steps = self.steps, .depth = self.depth };
        var found = false;
        if (look.ahead) {
            found = probe.alternatives(look.alts, pos, null);
        } else {
            const stop: Cont = .{ .kind = .look_end, .end_at = pos, .next = null };
            var start = pos + 1;
            while (start > 0 and !found) {
                start -= 1;
                found = probe.alternatives(look.alts, start, &stop);
                if (probe.exhausted or pos - start > 1024) break;
            }
        }
        self.steps = probe.steps;
        if (probe.exhausted) {
            self.exhausted = true;
            return false;
        }
        return found != look.negate;
    }

    fn repeatSingle(self: *Matcher, rep: *const Repeat, set: ByteSet, pos: usize, k: *const Cont) bool {
        var run: usize = 0;
        while (pos + run < self.text.len and run < rep.max and set.isSet(self.text[pos + run])) run += 1;
        if (run < rep.min) return false;
        if (rep.greedy) {
            var n = run;
            while (true) {
                if (self.resume_(k, pos + n)) return true;
                if (self.exhausted or n == rep.min) return false;
                n -= 1;
            }
        }
        var n: usize = rep.min;
        while (n <= run) : (n += 1) {
            if (self.resume_(k, pos + n)) return true;
            if (self.exhausted) return false;
        }
        return false;
    }

    /// After `count` iterations that started at `iter_start` and reached `pos`.
    fn repeatAfter(self: *Matcher, rep: *const Repeat, count: u32, iter_start: usize, pos: usize, k: ?*const Cont) bool {
        if (!self.tick()) return false;
        // An iteration that consumed nothing cannot loop again.
        const stalled = count > 0 and pos == iter_start;
        const can_more = count < rep.max and !stalled;
        const can_stop = count >= rep.min or stalled;
        const again: Cont = .{ .kind = .repeat, .rep = rep, .count = count + 1, .iter_start = pos, .next = k };
        if (rep.greedy) {
            if (can_more and self.seqAt(rep.body, 0, pos, &again)) return true;
            if (self.exhausted) return false;
            return can_stop and self.resume_(k, pos);
        }
        if (can_stop and self.resume_(k, pos)) return true;
        if (self.exhausted) return false;
        return can_more and self.seqAt(rep.body, 0, pos, &again);
    }

    fn atLineStart(self: *const Matcher, pos: usize) bool {
        if (pos == 0) return true;
        return self.flags.multiline and (self.text[pos - 1] == '\n' or self.text[pos - 1] == '\r');
    }

    fn atLineEnd(self: *const Matcher, pos: usize) bool {
        if (pos == self.text.len) return true;
        return self.flags.multiline and (self.text[pos] == '\n' or self.text[pos] == '\r');
    }

    fn atBoundary(self: *const Matcher, pos: usize) bool {
        const before = pos > 0 and isWord(self.text[pos - 1]);
        const after = pos < self.text.len and isWord(self.text[pos]);
        return before != after;
    }
};

fn expectFind(pattern: []const u8, text: []const u8, expected: ?[]const u8) !void {
    var re = try compile(std.testing.allocator, pattern);
    defer re.deinit();
    const span = re.find(text, 0);
    if (expected) |want| {
        const got = span orelse return error.TestExpectedMatch;
        try std.testing.expectEqualStrings(want, text[got.start..got.end]);
    } else {
        try std.testing.expect(span == null);
    }
}

test "regex matches literals classes anchors and quantifiers" {
    try expectFind("Box::leak", "let x = Box::leak(y);", "Box::leak");
    try expectFind("a.c", "xxabcxx", "abc");
    try expectFind("^foo", "bar\nfoo", null);
    try expectFind("(?m)^foo", "bar\nfoo", "foo");
    try expectFind("foo$", "foo\nbar", null);
    try expectFind("(?m)foo$", "foo\nbar", "foo");
    try expectFind("\\bas any\\b", "x as any;", "as any");
    try expectFind("\\bas any\\b", "x has anyone", null);
    try expectFind("[A-Za-z_]\\w*", "  _abc9 ", "_abc9");
    try expectFind("[^\"'\\n]+", "\"abc'", "abc");
    try expectFind("a{2,3}", "aaaa", "aaa");
    try expectFind("a{2,3}?", "aaaa", "aa");
    try expectFind("x{,", "x{,", "x{,");
    try expectFind("colou?r", "color", "color");
    try expectFind("(?i)HELLO", "say hello", "hello");
    try expectFind("(?i)[a-c]+", "xxABCaz", "ABCa");
}

test "regex handles alternation groups and lookaround" {
    try expectFind("cat|dog", "hotdog", "dog");
    try expectFind("(?:ab)+c", "xababc", "ababc");
    try expectFind("fmt\\.Sprintf(?=\\(\"%s:%d\")", "fmt.Sprintf(\"%s:%d\", h, p)", "fmt.Sprintf");
    try expectFind("fmt\\.Sprintf(?=\\(\"%s:%d\")", "fmt.Sprintf(\"%v\", h)", null);
    try expectFind("=>(?!\\s*\\{)\\s*x", "=> {x", null);
    try expectFind("=>(?!\\s*\\{)\\s*x", "=> x", "=> x");
    try expectFind("(?<=\\$)\\d+", "cost $42", "42");
    try expectFind("(?<!\\$)\\b\\d+", "$42 and 7", "7");
    try expectFind("(?<name>ab)c", "abc", "abc");
    try expectFind("[\\s\\S]{0,5}?=", "abc=d", "abc=");
}

test "regex compiles the built-in rule patterns and refuses what it cannot run" {
    const patterns = [_][]const u8{
        "(?m)\\bfunction\\s+[A-Za-z_$][\\w$]*\\s*(?:<[^>{}\\n]*>\\s*)?\\([^{}\\n]*\\)\\s*\\{\\s*return\\b[^{};\\n]+;?\\s*\\}|\\b(?:const|let|var)\\s+[A-Za-z_$][\\w$]*\\s*=\\s*(?:\\([^()\\n]*\\)|[A-Za-z_$][\\w$]*)\\s*=>(?!\\s*\\{)\\s*[^\\n;]+",
        "\\b(?:const|let|var)\\s+isRecord\\b\\s*(?::[\\s\\S]{0,300}?)?=\\s*(?:async\\s+)?(?:function\\b|(?:<[^>\\n]*>\\s*)?(?:\\([^)]*\\)|[A-Za-z_$][\\w$]*)\\s*(?::[\\s\\S]{0,300}?)?=>)",
        "type\\s+Result<[A-Za-z_]\\w*>\\s*=",
        "(?m)(?:(?::|\\bas\\b|=|<|,|\\||&|\\?|\\bextends)\\s*)any\\b",
    };
    for (patterns) |pattern| {
        var re = try compile(std.testing.allocator, pattern);
        re.deinit();
    }
    try expectFind(patterns[0], "const f = (a) => a + 1", "const f = (a) => a + 1");
    try expectFind(patterns[1], "const isRecord = (v: unknown): v is R =>", "const isRecord = (v: unknown): v is R =>");
    try expectFind(patterns[3], "let a: any = 1", ": any");
    for ([_][]const u8{ "(a", "a)", "[a", "*a", "\\1", "(?x)a", "a{3,1}", "\\q" }) |bad| {
        try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, bad));
    }
}

test "regex search gives up instead of stalling on catastrophic patterns" {
    var re = try compile(std.testing.allocator, "(?:a+)+b");
    defer re.deinit();
    const text: [64]u8 = @splat('a');
    try std.testing.expect(re.find(&text, 0) == null);
}
