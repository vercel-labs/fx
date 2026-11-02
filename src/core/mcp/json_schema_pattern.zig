const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const unicode_letter = @import("json_schema_unicode_letter.zig");

const Allocator = std.mem.Allocator;
const invalid_index = std.math.maxInt(usize);

pub const Limits = struct {
    max_depth: usize,
    max_states: usize,
    max_repeat: usize,
    max_steps: usize,
};

pub const Error = error{
    InvalidPattern,
    PatternLimitExceeded,
    InvalidUtf8,
} || Allocator.Error;

const Pair = struct { left: usize, right: usize };
const Repeat = struct { child: usize, min: usize, max: ?usize };
const Atom = struct { node: usize, quantifiable: bool = true };

const Node = union(enum) {
    empty,
    literal: u21,
    any,
    class: usize,
    concat: Pair,
    alternate: Pair,
    repeat: Repeat,
    assert_start,
    assert_end,
};

const Range = struct { first: u21, last: u21 };

fn isEcmascriptWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000D,
        0x0020,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        0xFEFF,
        => true,
        else => false,
    };
}

const CharacterClass = struct {
    range_start: usize,
    range_len: usize,
    negated: bool = false,
    ascii_digit: bool = false,
    ascii_word: bool = false,
    ecmascript_space: bool = false,
    not_ecmascript_space: bool = false,
    unicode_letter: bool = false,

    fn matches(self: CharacterClass, ranges: []const Range, codepoint: u21) bool {
        var matched = self.unicode_letter and unicode_letter.contains(codepoint);
        matched = matched or (self.ascii_digit and codepoint >= '0' and codepoint <= '9');
        matched = matched or (self.ascii_word and
            ((codepoint >= 'a' and codepoint <= 'z') or
                (codepoint >= 'A' and codepoint <= 'Z') or
                (codepoint >= '0' and codepoint <= '9') or
                codepoint == '_'));
        const is_space = isEcmascriptWhitespace(codepoint);
        matched = matched or (self.ecmascript_space and is_space);
        matched = matched or (self.not_ecmascript_space and !is_space);
        for (ranges[self.range_start..][0..self.range_len]) |range| {
            if (codepoint >= range.first and codepoint <= range.last) {
                matched = true;
                break;
            }
        }
        return if (self.negated) !matched else matched;
    }
};

const Parser = struct {
    alloc: Allocator,
    source: []const u8,
    limits: Limits,
    index: usize = 0,
    group_depth: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(CharacterClass) = .empty,
    ranges: std.ArrayList(Range) = .empty,

    fn deinit(self: *Parser) void {
        self.nodes.deinit(self.alloc);
        self.classes.deinit(self.alloc);
        self.ranges.deinit(self.alloc);
    }

    fn parse(self: *Parser) Error!usize {
        const root = try self.parseAlternation(null);
        if (self.index != self.source.len) return error.InvalidPattern;
        return root;
    }

    fn parseAlternation(self: *Parser, terminator: ?u8) Error!usize {
        var left = try self.parseSequence(terminator);
        while (self.peekByte() == '|') {
            self.index += 1;
            const right = try self.parseSequence(terminator);
            left = try self.addNode(.{ .alternate = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseSequence(self: *Parser, terminator: ?u8) Error!usize {
        var result: ?usize = null;
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (byte == '|' or (terminator != null and byte == terminator.?)) break;
            const item = try self.parseRepetition();
            result = if (result) |left|
                try self.addNode(.{ .concat = .{ .left = left, .right = item } })
            else
                item;
        }
        return result orelse try self.addNode(.empty);
    }

    fn parseRepetition(self: *Parser) Error!usize {
        const atom = try self.parseAtom();
        if (self.index >= self.source.len) return atom.node;
        if (!atom.quantifiable) switch (self.source[self.index]) {
            '*', '+', '?', '{' => return error.InvalidPattern,
            else => {},
        };
        var min: usize = undefined;
        var max: ?usize = undefined;
        switch (self.source[self.index]) {
            '*' => {
                self.index += 1;
                min = 0;
                max = null;
            },
            '+' => {
                self.index += 1;
                min = 1;
                max = null;
            },
            '?' => {
                self.index += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                self.index += 1;
                min = try self.parseCount();
                if (self.consumeByte('}')) {
                    max = min;
                } else {
                    if (!self.consumeByte(',')) return error.InvalidPattern;
                    max = if (self.consumeByte('}')) null else blk: {
                        const upper = try self.parseCount();
                        if (!self.consumeByte('}')) return error.InvalidPattern;
                        break :blk upper;
                    };
                }
            },
            else => return atom.node,
        }
        if (max) |upper| if (upper < min) return error.InvalidPattern;
        if (min > self.limits.max_repeat or (max orelse min) > self.limits.max_repeat) {
            return error.PatternLimitExceeded;
        }
        _ = self.consumeByte('?'); // Lazy quantifiers have identical acceptance semantics.
        if (self.index < self.source.len) switch (self.source[self.index]) {
            '*', '+', '?', '{' => return error.InvalidPattern,
            else => {},
        };
        return self.addNode(.{ .repeat = .{ .child = atom.node, .min = min, .max = max } });
    }

    fn parseAtom(self: *Parser) Error!Atom {
        if (self.index >= self.source.len) return error.InvalidPattern;
        const byte = self.source[self.index];
        switch (byte) {
            '^' => {
                self.index += 1;
                return .{ .node = try self.addNode(.assert_start), .quantifiable = false };
            },
            '$' => {
                self.index += 1;
                return .{ .node = try self.addNode(.assert_end), .quantifiable = false };
            },
            '.' => {
                self.index += 1;
                return .{ .node = try self.addNode(.any) };
            },
            '(' => {
                self.index += 1;
                if (self.peekByte() == '?') return error.InvalidPattern;
                if (self.group_depth >= self.limits.max_depth) {
                    return error.PatternLimitExceeded;
                }
                self.group_depth += 1;
                defer self.group_depth -= 1;
                const nested = try self.parseAlternation(')');
                if (!self.consumeByte(')')) return error.InvalidPattern;
                return .{ .node = nested };
            },
            '[' => return .{ .node = try self.parseCharacterClass() },
            '\\' => return .{ .node = try self.parseEscapeNode() },
            ')', ']', '}', '|', '*', '+', '?', '{' => return error.InvalidPattern,
            else => {
                const codepoint = try self.nextCodepoint();
                return .{ .node = try self.addNode(.{ .literal = codepoint }) };
            },
        }
    }

    fn parseEscapeNode(self: *Parser) Error!usize {
        self.index += 1;
        if (self.index >= self.source.len) return error.InvalidPattern;
        const byte = self.source[self.index];
        self.index += 1;
        switch (byte) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                var class = CharacterClass{
                    .range_start = self.ranges.items.len,
                    .range_len = 0,
                    .negated = std.ascii.isUpper(byte),
                };
                switch (std.ascii.toLower(byte)) {
                    'd' => class.ascii_digit = true,
                    'w' => class.ascii_word = true,
                    's' => class.ecmascript_space = true,
                    else => unreachable,
                }
                return self.addClassNode(class);
            },
            'p', 'P' => {
                if (!self.consumeByte('{')) return error.InvalidPattern;
                const start = self.index;
                while (self.index < self.source.len and self.source[self.index] != '}') : (self.index += 1) {}
                if (!self.consumeByte('}')) return error.InvalidPattern;
                const property = self.source[start .. self.index - 1];
                if (!std.mem.eql(u8, property, "Letter") and !std.mem.eql(u8, property, "L")) {
                    return error.InvalidPattern;
                }
                return self.addClassNode(.{
                    .range_start = self.ranges.items.len,
                    .range_len = 0,
                    .negated = byte == 'P',
                    .unicode_letter = true,
                });
            },
            'n' => return self.addNode(.{ .literal = '\n' }),
            'r' => return self.addNode(.{ .literal = '\r' }),
            't' => return self.addNode(.{ .literal = '\t' }),
            'f' => return self.addNode(.{ .literal = 0x0C }),
            'v' => return self.addNode(.{ .literal = 0x0B }),
            'x' => return self.addNode(.{ .literal = try self.parseHexCodepoint(2) }),
            'u' => {
                if (self.consumeByte('{')) {
                    const codepoint = try self.parseVariableHexCodepoint();
                    if (!self.consumeByte('}')) return error.InvalidPattern;
                    return self.addNode(.{ .literal = codepoint });
                }
                return self.addNode(.{ .literal = try self.parseHexCodepoint(4) });
            },
            '0' => {
                if (self.peekByte()) |next| if (std.ascii.isDigit(next)) {
                    return error.InvalidPattern;
                };
                return self.addNode(.{ .literal = 0 });
            },
            '1'...'9', 'b', 'B', 'c', 'k' => return error.InvalidPattern,
            else => {
                if (!isIdentityEscape(byte, false)) return error.InvalidPattern;
                return self.addNode(.{ .literal = byte });
            },
        }
    }

    fn parseCharacterClass(self: *Parser) Error!usize {
        self.index += 1;
        var class = CharacterClass{
            .range_start = self.ranges.items.len,
            .range_len = 0,
            .negated = self.consumeByte('^'),
        };
        var first = true;
        while (self.index < self.source.len) {
            if (self.source[self.index] == ']' and !first) {
                self.index += 1;
                class.range_len = self.ranges.items.len - class.range_start;
                return self.addClassNode(class);
            }
            const left = try self.parseClassAtom(&class);
            first = false;
            if (left == null) {
                if (self.peekByte() == '-' and self.index + 1 < self.source.len and
                    self.source[self.index + 1] != ']')
                {
                    return error.InvalidPattern;
                }
                continue;
            }
            if (self.peekByte() == '-' and self.index + 1 < self.source.len and
                self.source[self.index + 1] != ']')
            {
                self.index += 1;
                const right = (try self.parseClassAtom(&class)) orelse return error.InvalidPattern;
                if (right < left.?) return error.InvalidPattern;
                try self.ranges.append(self.alloc, .{ .first = left.?, .last = right });
            } else {
                try self.ranges.append(self.alloc, .{ .first = left.?, .last = left.? });
            }
            if (self.ranges.items.len - class.range_start > self.limits.max_states) {
                return error.PatternLimitExceeded;
            }
        }
        return error.InvalidPattern;
    }

    fn parseClassAtom(self: *Parser, class: *CharacterClass) Error!?u21 {
        if (self.index >= self.source.len) return error.InvalidPattern;
        if (self.source[self.index] != '\\') return try self.nextCodepoint();
        self.index += 1;
        if (self.index >= self.source.len) return error.InvalidPattern;
        const byte = self.source[self.index];
        self.index += 1;
        switch (byte) {
            'd' => {
                class.ascii_digit = true;
                return null;
            },
            'w' => {
                class.ascii_word = true;
                return null;
            },
            's' => {
                class.ecmascript_space = true;
                return null;
            },
            'S' => {
                class.not_ecmascript_space = true;
                return null;
            },
            'D', 'W', 'p', 'P', 'b', 'B', '1'...'9', 'c', 'k' => return error.InvalidPattern,
            '0' => {
                if (self.peekByte()) |next| if (std.ascii.isDigit(next)) {
                    return error.InvalidPattern;
                };
                return 0;
            },
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'f' => return 0x0C,
            'v' => return 0x0B,
            'x' => return try self.parseHexCodepoint(2),
            'u' => return try self.parseHexCodepoint(4),
            else => {
                if (!isIdentityEscape(byte, true)) return error.InvalidPattern;
                return @as(u21, byte);
            },
        }
    }

    fn addClassNode(self: *Parser, class: CharacterClass) Error!usize {
        if (self.classes.items.len >= self.limits.max_states) return error.PatternLimitExceeded;
        const index = self.classes.items.len;
        try self.classes.append(self.alloc, class);
        return self.addNode(.{ .class = index });
    }

    fn addNode(self: *Parser, node: Node) Error!usize {
        if (self.nodes.items.len >= self.limits.max_states) return error.PatternLimitExceeded;
        const index = self.nodes.items.len;
        try self.nodes.append(self.alloc, node);
        return index;
    }

    fn parseCount(self: *Parser) Error!usize {
        const start = self.index;
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {}
        if (self.index == start) return error.InvalidPattern;
        return std.fmt.parseInt(usize, self.source[start..self.index], 10) catch
            return error.PatternLimitExceeded;
    }

    fn parseHexCodepoint(self: *Parser, digits: usize) Error!u21 {
        if (digits > self.source.len - self.index) return error.InvalidPattern;
        const value = std.fmt.parseInt(u21, self.source[self.index..][0..digits], 16) catch
            return error.InvalidPattern;
        self.index += digits;
        if (!std.unicode.utf8ValidCodepoint(value)) return error.InvalidPattern;
        return value;
    }

    fn parseVariableHexCodepoint(self: *Parser) Error!u21 {
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '}') : (self.index += 1) {}
        if (self.index == start or self.index - start > 6) return error.InvalidPattern;
        const value = std.fmt.parseInt(u21, self.source[start..self.index], 16) catch
            return error.InvalidPattern;
        if (!std.unicode.utf8ValidCodepoint(value)) return error.InvalidPattern;
        return value;
    }

    fn nextCodepoint(self: *Parser) Error!u21 {
        const width = std.unicode.utf8ByteSequenceLength(self.source[self.index]) catch
            return error.InvalidUtf8;
        if (width > self.source.len - self.index) return error.InvalidUtf8;
        const codepoint = display_width.decodeUtf8Sequence(self.source[self.index..][0..width]) catch
            return error.InvalidUtf8;
        self.index += width;
        return codepoint;
    }

    fn peekByte(self: *const Parser) ?u8 {
        return if (self.index < self.source.len) self.source[self.index] else null;
    }

    fn consumeByte(self: *Parser, expected: u8) bool {
        if (self.peekByte() != expected) return false;
        self.index += 1;
        return true;
    }
};

fn isIdentityEscape(byte: u8, in_class: bool) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        '-' => in_class,
        else => false,
    };
}

const Op = enum { epsilon, literal, any, class, split, assert_start, assert_end, accept };
const Instruction = struct {
    op: Op,
    out: usize = invalid_index,
    out1: usize = invalid_index,
    value: usize = 0,
};
const Patch = struct { instruction: usize, second: bool = false };
const Fragment = struct { start: usize, outs: std.ArrayList(Patch) };

const Compiler = struct {
    alloc: Allocator,
    nodes: []const Node,
    limits: Limits,
    instructions: std.ArrayList(Instruction) = .empty,

    fn deinit(self: *Compiler) void {
        self.instructions.deinit(self.alloc);
    }

    fn compile(self: *Compiler, node_index: usize) Error!usize {
        var fragment = try self.compileNode(node_index);
        defer fragment.outs.deinit(self.alloc);
        const accept = try self.addInstruction(.{ .op = .accept });
        self.patch(fragment.outs.items, accept);
        return fragment.start;
    }

    fn compileNode(self: *Compiler, node_index: usize) Error!Fragment {
        return switch (self.nodes[node_index]) {
            .empty => self.single(.{ .op = .epsilon }, false),
            .literal => |value| self.single(.{ .op = .literal, .value = value }, false),
            .any => self.single(.{ .op = .any }, false),
            .class => |value| self.single(.{ .op = .class, .value = value }, false),
            .assert_start => self.single(.{ .op = .assert_start }, false),
            .assert_end => self.single(.{ .op = .assert_end }, false),
            .concat => |pair| self.compileConcat(pair),
            .alternate => |pair| self.compileAlternate(pair),
            .repeat => |repeat| self.compileRepeat(repeat),
        };
    }

    fn compileConcat(self: *Compiler, pair: Pair) Error!Fragment {
        var left = try self.compileNode(pair.left);
        errdefer left.outs.deinit(self.alloc);
        var right = try self.compileNode(pair.right);
        errdefer right.outs.deinit(self.alloc);
        const left_owned = left;
        const right_owned = right;
        left.outs = .empty;
        right.outs = .empty;
        return self.concat(left_owned, right_owned);
    }

    fn compileAlternate(self: *Compiler, pair: Pair) Error!Fragment {
        var left = try self.compileNode(pair.left);
        errdefer left.outs.deinit(self.alloc);
        var right = try self.compileNode(pair.right);
        errdefer right.outs.deinit(self.alloc);
        const left_owned = left;
        const right_owned = right;
        left.outs = .empty;
        right.outs = .empty;
        return self.alternate(left_owned, right_owned);
    }

    fn compileRepeat(self: *Compiler, repeat: Repeat) Error!Fragment {
        var result = try self.single(.{ .op = .epsilon }, false);
        errdefer result.outs.deinit(self.alloc);
        var count: usize = 0;
        while (count < repeat.min) : (count += 1) {
            result = try self.concat(result, try self.compileNode(repeat.child));
        }
        if (repeat.max) |maximum| {
            while (count < maximum) : (count += 1) {
                result = try self.concat(result, try self.optional(try self.compileNode(repeat.child)));
            }
        } else {
            result = try self.concat(result, try self.star(try self.compileNode(repeat.child)));
        }
        return result;
    }

    fn concat(self: *Compiler, left_value: Fragment, right_value: Fragment) Error!Fragment {
        var left = left_value;
        var right = right_value;
        self.patch(left.outs.items, right.start);
        left.outs.deinit(self.alloc);
        const outs = right.outs;
        right.outs = .empty;
        return .{ .start = left.start, .outs = outs };
    }

    fn alternate(self: *Compiler, left_value: Fragment, right_value: Fragment) Error!Fragment {
        var left = left_value;
        defer left.outs.deinit(self.alloc);
        var right = right_value;
        defer right.outs.deinit(self.alloc);
        const split = try self.addInstruction(.{ .op = .split, .out = left.start, .out1 = right.start });
        var outs: std.ArrayList(Patch) = .empty;
        errdefer outs.deinit(self.alloc);
        try outs.appendSlice(self.alloc, left.outs.items);
        try outs.appendSlice(self.alloc, right.outs.items);
        return .{ .start = split, .outs = outs };
    }

    fn optional(self: *Compiler, value: Fragment) Error!Fragment {
        var child = value;
        defer child.outs.deinit(self.alloc);
        const split = try self.addInstruction(.{ .op = .split, .out = child.start });
        var outs: std.ArrayList(Patch) = .empty;
        errdefer outs.deinit(self.alloc);
        try outs.appendSlice(self.alloc, child.outs.items);
        try outs.append(self.alloc, .{ .instruction = split, .second = true });
        return .{ .start = split, .outs = outs };
    }

    fn star(self: *Compiler, value: Fragment) Error!Fragment {
        var child = value;
        defer child.outs.deinit(self.alloc);
        const split = try self.addInstruction(.{ .op = .split, .out = child.start });
        self.patch(child.outs.items, split);
        var outs: std.ArrayList(Patch) = .empty;
        errdefer outs.deinit(self.alloc);
        try outs.append(self.alloc, .{ .instruction = split, .second = true });
        return .{ .start = split, .outs = outs };
    }

    fn single(self: *Compiler, instruction: Instruction, second: bool) Error!Fragment {
        const index = try self.addInstruction(instruction);
        var outs: std.ArrayList(Patch) = .empty;
        errdefer outs.deinit(self.alloc);
        try outs.append(self.alloc, .{ .instruction = index, .second = second });
        return .{ .start = index, .outs = outs };
    }

    fn addInstruction(self: *Compiler, instruction: Instruction) Error!usize {
        if (self.instructions.items.len >= self.limits.max_states) {
            return error.PatternLimitExceeded;
        }
        const index = self.instructions.items.len;
        try self.instructions.append(self.alloc, instruction);
        return index;
    }

    fn patch(self: *Compiler, patches: []const Patch, target: usize) void {
        for (patches) |item| {
            if (item.second) {
                self.instructions.items[item.instruction].out1 = target;
            } else {
                self.instructions.items[item.instruction].out = target;
            }
        }
    }
};

pub fn validate(alloc: Allocator, source: []const u8, limits: Limits) Error!void {
    var parser = Parser{ .alloc = alloc, .source = source, .limits = limits };
    defer parser.deinit();
    const root = try parser.parse();
    var compiler = Compiler{ .alloc = alloc, .nodes = parser.nodes.items, .limits = limits };
    defer compiler.deinit();
    _ = try compiler.compile(root);
}

pub fn matches(
    alloc: Allocator,
    source: []const u8,
    text: []const u8,
    limits: Limits,
    steps: *usize,
) Error!bool {
    var parser = Parser{ .alloc = alloc, .source = source, .limits = limits };
    defer parser.deinit();
    const root = try parser.parse();
    var compiler = Compiler{ .alloc = alloc, .nodes = parser.nodes.items, .limits = limits };
    defer compiler.deinit();
    const start = try compiler.compile(root);

    const instructions = compiler.instructions.items;
    var current = try std.bit_set.Dynamic.initEmpty(alloc, instructions.len);
    defer current.deinit(alloc);
    var next = try std.bit_set.Dynamic.initEmpty(alloc, instructions.len);
    defer next.deinit(alloc);
    var visited = try std.bit_set.Dynamic.initEmpty(alloc, instructions.len);
    defer visited.deinit(alloc);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(alloc);

    var byte_index: usize = 0;
    while (true) {
        visited.unsetAll();
        try addClosure(
            alloc,
            instructions,
            &current,
            &visited,
            &stack,
            start,
            byte_index,
            text.len,
            limits,
            steps,
        );
        if (containsAccept(instructions, &current)) return true;
        if (byte_index == text.len) return false;

        const width = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch
            return error.InvalidUtf8;
        if (width > text.len - byte_index) return error.InvalidUtf8;
        const codepoint = display_width.decodeUtf8Sequence(text[byte_index..][0..width]) catch
            return error.InvalidUtf8;
        const next_byte_index = byte_index + width;
        next.unsetAll();
        var iterator = current.iterator(.{});
        while (iterator.next()) |instruction_index| {
            const instruction = instructions[instruction_index];
            const matched = switch (instruction.op) {
                .literal => codepoint == instruction.value,
                .any => codepoint != '\n' and codepoint != '\r' and
                    codepoint != 0x2028 and codepoint != 0x2029,
                .class => parser.classes.items[instruction.value].matches(parser.ranges.items, codepoint),
                else => false,
            };
            if (!matched) continue;
            try consumeStep(limits, steps);
            visited.unsetAll();
            try addClosure(
                alloc,
                instructions,
                &next,
                &visited,
                &stack,
                instruction.out,
                next_byte_index,
                text.len,
                limits,
                steps,
            );
        }
        std.mem.swap(std.bit_set.Dynamic, &current, &next);
        byte_index = next_byte_index;
    }
}

fn addClosure(
    alloc: Allocator,
    instructions: []const Instruction,
    states: *std.bit_set.Dynamic,
    visited: *std.bit_set.Dynamic,
    stack: *std.ArrayList(usize),
    start: usize,
    byte_index: usize,
    text_len: usize,
    limits: Limits,
    steps: *usize,
) Error!void {
    if (start == invalid_index) return error.InvalidPattern;
    stack.clearRetainingCapacity();
    try stack.append(alloc, start);
    while (stack.pop()) |index| {
        if (visited.isSet(index)) continue;
        visited.set(index);
        try consumeStep(limits, steps);
        const instruction = instructions[index];
        switch (instruction.op) {
            .epsilon => try stack.append(alloc, instruction.out),
            .split => {
                try stack.append(alloc, instruction.out);
                try stack.append(alloc, instruction.out1);
            },
            .assert_start => if (byte_index == 0) try stack.append(alloc, instruction.out),
            .assert_end => if (byte_index == text_len) try stack.append(alloc, instruction.out),
            else => states.set(index),
        }
    }
}

fn containsAccept(instructions: []const Instruction, states: *const std.bit_set.Dynamic) bool {
    var iterator = states.iterator(.{});
    while (iterator.next()) |index| if (instructions[index].op == .accept) return true;
    return false;
}

fn consumeStep(limits: Limits, steps: *usize) Error!void {
    steps.* = std.math.add(usize, steps.*, 1) catch return error.PatternLimitExceeded;
    if (steps.* > limits.max_steps) return error.PatternLimitExceeded;
}

test "bounded pattern matching covers the JSON Schema interoperability subset" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .max_depth = 64, .max_states = 256, .max_repeat = 64, .max_steps = 10_000 };
    const cases = [_]struct { pattern: []const u8, text: []const u8, matches: bool }{
        .{ .pattern = "^a*$", .text = "aaa", .matches = true },
        .{ .pattern = "^a*$", .text = "abc", .matches = false },
        .{ .pattern = "a+", .text = "xxaayy", .matches = true },
        .{ .pattern = "f.*o", .text = "foo", .matches = true },
        .{ .pattern = "[0-9]{2,}", .text = "v12", .matches = true },
        .{ .pattern = "^(ab|cd)?$", .text = "cd", .matches = true },
        .{ .pattern = "^\\p{Letter}+$", .text = "π", .matches = true },
        .{ .pattern = "^\\p{Letter}+$", .text = "123", .matches = false },
    };
    for (cases) |case| {
        var steps: usize = 0;
        try std.testing.expectEqual(
            case.matches,
            try matches(alloc, case.pattern, case.text, limits, &steps),
        );
    }
}

test "ECMAScript whitespace classification covers exact codepoint boundaries" {
    const whitespace = [_]u21{
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
        0xFEFF,
    };
    for (whitespace) |codepoint| try std.testing.expect(isEcmascriptWhitespace(codepoint));

    const non_whitespace = [_]u21{
        0x0008, 0x000E, 0x001F, 0x0021, 0x0085, 0x009F, 0x00A1, 0x167F,
        0x1681, 0x180E, 0x1FFF, 0x200B, 0x2027, 0x202A, 0x202E, 0x2030,
        0x205E, 0x2060, 0x2FFF, 0x3001, 0xFEFE, 0xFF00,
    };
    for (non_whitespace) |codepoint| try std.testing.expect(!isEcmascriptWhitespace(codepoint));
}

test "ECMAScript whitespace escapes share exact standalone and class semantics" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .max_depth = 64, .max_states = 256, .max_repeat = 64, .max_steps = 10_000 };
    const whitespace = [_]u21{
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
        0xFEFF,
    };
    const patterns = [_][]const u8{ "^\\s$", "^\\S$", "^[\\s]$", "^[^\\s]$", "^[\\S]$", "^[^\\S]$" };
    const whitespace_results = [_]bool{ true, false, true, false, false, true };
    const non_whitespace_results = [_]bool{ false, true, false, true, true, false };

    for (whitespace) |codepoint| {
        var encoded: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &encoded);
        for (patterns, whitespace_results) |pattern, expected| {
            var steps: usize = 0;
            try std.testing.expectEqual(expected, try matches(alloc, pattern, encoded[0..len], limits, &steps));
        }
    }

    const non_whitespace = [_]u21{ 0x0008, 0x000E, 0x0021, 0x0085, 0x180E, 0x200B, 0x202A, 0x2060, 0x3001, 0xFF00 };
    for (non_whitespace) |codepoint| {
        var encoded: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &encoded);
        for (patterns, non_whitespace_results) |pattern, expected| {
            var steps: usize = 0;
            try std.testing.expectEqual(expected, try matches(alloc, pattern, encoded[0..len], limits, &steps));
        }
    }

    const rejected = [_][]const u8{ "\u{00A0}", "\u{FEFF}", "\u{2003}", "\u{2028}", "\u{2029}" };
    for (rejected) |text| {
        var steps: usize = 0;
        try std.testing.expect(!try matches(alloc, "^\\S+$", text, limits, &steps));
    }
}

test "pattern compilation and matching reject unsupported or over-budget behavior" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .max_depth = 4, .max_states = 32, .max_repeat = 8, .max_steps = 64 };
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "(?=a)", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "(a)\\1", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "^\\cC$", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "^\\cc$", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "^\\p{digit}+$", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "\\q", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "[\\q]", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "\\00", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "[\\00]", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "]", limits));
    try std.testing.expectError(error.InvalidPattern, validate(alloc, "}", limits));
    for ([_][]const u8{ "[\\s-a]", "[\\w-a]", "^*", "$+" }) |source| {
        try std.testing.expectError(error.InvalidPattern, validate(alloc, source, limits));
    }
    try validate(alloc, "[\\s-]", limits);
    try validate(alloc, "(^)?", limits);
    try std.testing.expectError(error.PatternLimitExceeded, validate(alloc, "a{9}", limits));
    try validate(alloc, "((((a))))", limits);
    try std.testing.expectError(
        error.PatternLimitExceeded,
        validate(alloc, "(((((a)))))", limits),
    );
    var nul_steps: usize = 0;
    try std.testing.expect(try matches(alloc, "^[\\0]$", &[_]u8{0}, limits, &nul_steps));
    var steps: usize = 0;
    try std.testing.expectError(
        error.PatternLimitExceeded,
        matches(alloc, "(a|aa)*b", "aaaaaaaaaaaaaaaa", limits, &steps),
    );
}
