//! Compiles a rule's `match:` expression tree.
//!
//! Leaves locate spans in the buffer (`regex`, `ast`, `shell`), test its
//! context (`lang`, `path`), test what the session already did (`did`), or
//! ask a model (`llm`); `all`, `any`, `not` and `if`/`then`/`else` combine
//! them; `in`, `count`, `inside`, `notInside`, `has` and `notHas` filter the
//! located spans. Children of `all` and `any` sort by cost, so a cheap leaf
//! decides before a parse or a model is consulted. Evaluation lives in
//! `evaluate.zig`.
const std = @import("std");
const regex = @import("regex.zig");
const regions = @import("regions.zig");
const ast = @import("ast.zig");
const shell_code = @import("shell_code.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const cost_context: u8 = 0;
pub const cost_regex: u8 = 1;
pub const cost_ast: u8 = 2;
pub const cost_judge: u8 = 3;

pub const default_judge_roles = [_][]const u8{ "tiny", "small" };

pub const PathPredicate = struct {
    globs: []const []const u8 = &.{},
    patterns: []const *const regex.Regex = &.{},
    pattern_sources: []const []const u8 = &.{},
    under: []const []const u8 = &.{},
    outside: []const []const u8 = &.{},
};

pub const Did = struct {
    tools: []const []const u8 = &.{},
    path: ?PathPredicate = null,
    patterns: []const *const regex.Regex = &.{},
    pattern_sources: []const []const u8 = &.{},
    within: ?usize = null,
};

pub const Kind = union(enum) {
    regex: struct {
        patterns: []const *const regex.Regex,
        sources: []const []const u8,
        /// Null accepts every region.
        regions: ?[]const regions.Kind,
    },
    ast: struct {
        patterns: []const ast.Pattern,
        sources: []const []const u8,
        selector: ast.Selector,
        where: []const ast.Constraint,
    },
    shell: struct { language: shell_code.Language, kernel: bool },
    lang: []const []const u8,
    path: PathPredicate,
    did: Did,
    llm: struct { question: []const u8, roles: []const []const u8 },
    all: []const *const Node,
    any: []const *const Node,
    not: *const Node,
    @"if": struct { guard: *const Node, then: *const Node, @"else": ?*const Node },
};

pub const Node = struct {
    kind: Kind,
    count: u32 = 1,
    cost: u8 = 0,
    inside: ?*const Node = null,
    not_inside: ?*const Node = null,
    has: ?*const Node = null,
    not_has: ?*const Node = null,
};

pub const Program = struct {
    root: *const Node,
    needs_ast: bool,
    needs_judge: bool,
    /// A compact human-readable form for `proto-fx ttsr list` and logs.
    description: []const u8,
    /// Literals the buffer must contain for any match; empty disables the
    /// bulk prefilter.
    literals: []const []const u8,
    /// Plain-literal regex sources the stream prefilter may scan deltas for.
    incremental_literals: []const []const u8,
};

pub const Compiled = struct {
    program: ?Program,
    errors: []const []const u8,
};

const leaf_keys = [_][]const u8{ "regex", "ast", "shell", "lang", "path", "did", "llm", "all", "any", "not", "if" };
const modifier_keys = [_][]const u8{ "in", "count", "inside", "notInside", "has", "notHas", "where", "strictness", "selector", "model", "then", "else" };
const path_keys = [_][]const u8{ "glob", "under", "outside", "regex" };
const did_keys = [_][]const u8{ "tool", "path", "args", "within" };
const strictness_values = [_][]const u8{ "cst", "smart", "ast", "relaxed", "signature", "template" };

/// Compiles `spec`. All memory, including the regexes, comes from `arena`.
pub fn compile(arena: Allocator, spec: Value) !Compiled {
    var compiler: Compiler = .{ .arena = arena };
    const root = try compiler.node(spec, "match");
    if (root == null or compiler.errors.items.len > 0) {
        if (compiler.errors.items.len == 0) try compiler.fail("match: could not compile", .{});
        return .{ .program = null, .errors = compiler.errors.items };
    }
    return .{ .program = try finishProgram(arena, root.?, compiler), .errors = &.{} };
}

/// Compiles the flat `condition:` and `astCondition:` lists. Tolerant like
/// proto: an invalid pattern is reported and dropped, and the rule keeps
/// whatever compiled.
pub fn compileLegacy(arena: Allocator, condition: []const []const u8, ast_condition: []const []const u8) !Compiled {
    var compiler: Compiler = .{ .arena = arena };
    var branches: std.ArrayList(Value) = .empty;
    for (condition) |pattern| {
        if (regex.compile(arena, pattern)) |_| {
            var object: std.json.ObjectMap = .empty;
            try object.put(arena, "regex", .{ .string = pattern });
            try branches.append(arena, .{ .object = object });
        } else |_| try compiler.fail("condition: invalid regex /{s}/", .{pattern});
    }
    for (ast_condition) |pattern| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "ast", .{ .string = pattern });
        try branches.append(arena, .{ .object = object });
    }
    if (branches.items.len == 0) return .{ .program = null, .errors = compiler.errors.items };
    var list = std.json.Array.init(arena);
    try list.appendSlice(branches.items);
    const spec: Value = if (branches.items.len == 1) branches.items[0] else .{ .array = list };
    const root = try compiler.node(spec, "condition") orelse return .{ .program = null, .errors = compiler.errors.items };
    return .{ .program = try finishProgram(arena, root, compiler), .errors = compiler.errors.items };
}

fn finishProgram(arena: Allocator, root: *const Node, compiler: Compiler) !Program {
    var description: std.ArrayList(u8) = .empty;
    try describe(arena, &description, root);
    return .{
        .root = root,
        .needs_ast = compiler.needs_ast,
        .needs_judge = compiler.needs_judge,
        .description = description.items,
        .literals = try literalsOf(arena, root),
        .incremental_literals = try incrementalLiteralsOf(arena, root),
    };
}

fn isKey(list: []const []const u8, key: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, key)) return true;
    return false;
}

/// A string or a list of strings, trimmed, empties dropped; null for any
/// other shape.
fn stringList(arena: Allocator, value: Value) !?[]const []const u8 {
    switch (value) {
        .string => |s| {
            const token = std.mem.trim(u8, s, " \t\r\n");
            if (token.len == 0) return &.{};
            const out = try arena.alloc([]const u8, 1);
            out[0] = token;
            return out;
        },
        .array => |items| {
            var out: std.ArrayList([]const u8) = .empty;
            for (items.items) |item| {
                if (item != .string) return null;
                const token = std.mem.trim(u8, item.string, " \t\r\n");
                if (token.len > 0) try out.append(arena, token);
            }
            return out.items;
        },
        else => return null,
    }
}

const Compiler = struct {
    arena: Allocator,
    errors: std.ArrayList([]const u8) = .empty,
    needs_ast: bool = false,
    needs_judge: bool = false,

    fn fail(self: *Compiler, comptime fmt: []const u8, args: anytype) !void {
        try self.errors.append(self.arena, try self.arena.print(fmt, args));
    }

    fn make(self: *Compiler, value: Node) !*Node {
        const out = try self.arena.create(Node);
        out.* = value;
        return out;
    }

    fn node(self: *Compiler, spec: Value, path: []const u8) error{OutOfMemory}!?*const Node {
        switch (spec) {
            .string => |s| {
                var object: std.json.ObjectMap = .empty;
                try object.put(self.arena, "regex", .{ .string = s });
                return self.regexLeaf(object, path);
            },
            .array => |items| return self.group(.any, items.items, path),
            .object => |object| {
                var present: ?[]const u8 = null;
                var conflict = false;
                for (leaf_keys) |key| if (object.get(key) != null) {
                    if (present != null) conflict = true;
                    present = present orelse key;
                };
                const kind = present orelse {
                    try self.fail("{s}: needs one of regex, ast, shell, lang, path, did, llm, all, any, not, if", .{path});
                    return null;
                };
                if (conflict) {
                    try self.fail("{s}: has conflicting keys; wrap them in all: or any:", .{path});
                    return null;
                }
                var keys = object.iterator();
                while (keys.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (!isKey(&leaf_keys, key) and !isKey(&modifier_keys, key)) try self.fail("{s}: unknown key \"{s}\"", .{ path, key });
                }
                const owners = [_][2][]const u8{ .{ "model", "llm" }, .{ "then", "if" }, .{ "else", "if" } };
                for (owners) |pair| if (object.get(pair[0]) != null and !std.mem.eql(u8, kind, pair[1])) {
                    try self.fail("{s}.{s}: only applies to {s} conditions", .{ path, pair[0], pair[1] });
                    return null;
                };
                if (std.mem.eql(u8, kind, "all") or std.mem.eql(u8, kind, "any")) {
                    const children = object.get(kind).?;
                    if (children != .array) {
                        try self.fail("{s}.{s}: expected a list", .{ path, kind });
                        return null;
                    }
                    const child_path = try self.arena.print("{s}.{s}", .{ path, kind });
                    if (kind[1] == 'l') return self.group(.all, children.array.items, child_path);
                    return self.group(.any, children.array.items, child_path);
                }
                if (std.mem.eql(u8, kind, "not")) {
                    const child = try self.node(object.get("not").?, try self.arena.print("{s}.not", .{path})) orelse return null;
                    return self.withModifiers(.{ .kind = .{ .not = child } }, object, path);
                }
                if (std.mem.eql(u8, kind, "if")) return self.ifLeaf(object, path);
                if (std.mem.eql(u8, kind, "lang")) return self.langLeaf(object, path);
                if (std.mem.eql(u8, kind, "path")) {
                    const predicate = try self.pathPredicate(object.get("path").?, try self.arena.print("{s}.path", .{path})) orelse return null;
                    return self.withModifiers(.{ .kind = .{ .path = predicate } }, object, path);
                }
                if (std.mem.eql(u8, kind, "did")) return self.didLeaf(object, path);
                if (std.mem.eql(u8, kind, "llm")) return self.llmLeaf(object, path);
                if (std.mem.eql(u8, kind, "ast")) return self.astLeaf(object, path);
                if (std.mem.eql(u8, kind, "shell")) return self.shellLeaf(object, path);
                return self.regexLeaf(object, path);
            },
            else => {
                try self.fail("{s}: expected a string, list, or mapping", .{path});
                return null;
            },
        }
    }

    fn group(self: *Compiler, comptime which: enum { all, any }, specs: []const Value, path: []const u8) !?*const Node {
        var children: std.ArrayList(*const Node) = .empty;
        for (specs, 0..) |spec, index| {
            if (try self.node(spec, try self.arena.print("{s}[{d}]", .{ path, index }))) |child| try children.append(self.arena, child);
        }
        if (children.items.len == 0) {
            try self.fail("{s}: needs at least one condition", .{path});
            return null;
        }
        // Stable: authored order survives within a cost class.
        std.sort.insertion(*const Node, children.items, {}, struct {
            fn less(_: void, a: *const Node, b: *const Node) bool {
                return a.cost < b.cost;
            }
        }.less);
        const kind: Kind = if (which == .all) .{ .all = children.items } else .{ .any = children.items };
        return self.withModifiers(.{ .kind = kind }, .empty, path);
    }

    fn ifLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const then_spec = object.get("then") orelse {
            try self.fail("{s}.if: needs a then: branch", .{path});
            return null;
        };
        const guard = try self.node(object.get("if").?, try self.arena.print("{s}.if", .{path}));
        const then = try self.node(then_spec, try self.arena.print("{s}.then", .{path}));
        const otherwise = if (object.get("else")) |spec| try self.node(spec, try self.arena.print("{s}.else", .{path})) else null;
        if (guard == null or then == null or (object.get("else") != null and otherwise == null)) return null;
        return self.withModifiers(.{ .kind = .{ .@"if" = .{ .guard = guard.?, .then = then.?, .@"else" = otherwise } } }, object, path);
    }

    fn langLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const langs = try stringList(self.arena, object.get("lang").?) orelse &.{};
        if (langs.len == 0) {
            try self.fail("{s}.lang: expected a language name or list of names", .{path});
            return null;
        }
        const lowered = try self.arena.alloc([]const u8, langs.len);
        for (langs, lowered) |lang, *out| out.* = try std.ascii.allocLowerString(self.arena, lang);
        return self.withModifiers(.{ .kind = .{ .lang = lowered } }, object, path);
    }

    fn regexList(self: *Compiler, value: Value, path: []const u8) !?struct { sources: []const []const u8, compiled: []const *const regex.Regex } {
        const sources = try stringList(self.arena, value) orelse &.{};
        if (sources.len == 0) {
            try self.fail("{s}: expected a pattern or list of patterns", .{path});
            return null;
        }
        const compiled = try self.arena.alloc(*const regex.Regex, sources.len);
        for (sources, compiled) |source, *out| out.* = try self.compileRegex(source, path) orelse return null;
        return .{ .sources = sources, .compiled = compiled };
    }

    fn compileRegex(self: *Compiler, source: []const u8, path: []const u8) !?*const regex.Regex {
        const re = regex.compile(self.arena, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => {
                try self.fail("{s}: invalid regex /{s}/", .{ path, source });
                return null;
            },
        };
        const out = try self.arena.create(regex.Regex);
        out.* = re;
        return out;
    }

    fn pathPredicate(self: *Compiler, spec: Value, path: []const u8) !?PathPredicate {
        var predicate: PathPredicate = .{};
        if (try stringList(self.arena, spec)) |globs| {
            if (globs.len == 0) {
                try self.fail("{s}: expected a glob or list of globs", .{path});
                return null;
            }
            predicate.globs = globs;
            return predicate;
        }
        if (spec != .object) {
            try self.fail("{s}: expected a glob, a list of globs, or a mapping of glob, under, outside, regex", .{path});
            return null;
        }
        var keys = spec.object.iterator();
        while (keys.next()) |entry| if (!isKey(&path_keys, entry.key_ptr.*)) {
            try self.fail("{s}: unknown key \"{s}\"; expected glob, under, outside, regex", .{ path, entry.key_ptr.* });
            return null;
        };
        if (spec.object.get("glob")) |value| {
            const globs = try stringList(self.arena, value) orelse &.{};
            if (globs.len == 0) {
                try self.fail("{s}.glob: expected a glob or list of globs", .{path});
                return null;
            }
            predicate.globs = globs;
        }
        if (spec.object.get("regex")) |value| {
            const list = try self.regexList(value, try self.arena.print("{s}.regex", .{path})) orelse return null;
            predicate.pattern_sources = list.sources;
            predicate.patterns = list.compiled;
        }
        inline for (.{ "under", "outside" }) |key| {
            if (spec.object.get(key)) |value| {
                const roots = try stringList(self.arena, value) orelse &.{};
                if (roots.len == 0) {
                    try self.fail("{s}.{s}: expected a directory or list of directories", .{ path, key });
                    return null;
                }
                @field(predicate, key) = roots;
            }
        }
        if (predicate.globs.len == 0 and predicate.patterns.len == 0 and predicate.under.len == 0 and predicate.outside.len == 0) {
            try self.fail("{s}: needs one of glob, under, outside, regex", .{path});
            return null;
        }
        return predicate;
    }

    fn didLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        var did: Did = .{};
        const spec = object.get("did").?;
        if (try stringList(self.arena, spec)) |tools| {
            if (tools.len == 0) {
                try self.fail("{s}.did: expected a tool name or list of tool names", .{path});
                return null;
            }
            did.tools = tools;
            return self.withModifiers(.{ .kind = .{ .did = did } }, object, path);
        }
        if (spec != .object) {
            try self.fail("{s}.did: expected a tool name or a mapping of tool, path, args, within", .{path});
            return null;
        }
        var keys = spec.object.iterator();
        while (keys.next()) |entry| if (!isKey(&did_keys, entry.key_ptr.*)) {
            try self.fail("{s}.did: unknown key \"{s}\"; expected tool, path, args, within", .{ path, entry.key_ptr.* });
            return null;
        };
        if (spec.object.get("tool")) |value| {
            const tools = try stringList(self.arena, value) orelse &.{};
            if (tools.len == 0) {
                try self.fail("{s}.did.tool: expected a tool name or list of tool names", .{path});
                return null;
            }
            did.tools = tools;
        }
        if (spec.object.get("path")) |value| did.path = try self.pathPredicate(value, try self.arena.print("{s}.did.path", .{path})) orelse return null;
        if (spec.object.get("args")) |value| {
            const list = try self.regexList(value, try self.arena.print("{s}.did.args", .{path})) orelse return null;
            did.pattern_sources = list.sources;
            did.patterns = list.compiled;
        }
        if (spec.object.get("within")) |value| {
            const within = positiveInt(value) orelse {
                try self.fail("{s}.did.within: expected a positive integer", .{path});
                return null;
            };
            did.within = within;
        }
        if (did.tools.len == 0 and did.path == null and did.patterns.len == 0) {
            try self.fail("{s}.did: needs one of tool, path, args", .{path});
            return null;
        }
        return self.withModifiers(.{ .kind = .{ .did = did } }, object, path);
    }

    fn llmLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const spec = object.get("llm").?;
        const question = if (spec == .string) std.mem.trim(u8, spec.string, " \t\r\n") else "";
        if (question.len == 0) {
            try self.fail("{s}.llm: expected a yes/no question about the buffer", .{path});
            return null;
        }
        var roles: []const []const u8 = &default_judge_roles;
        if (object.get("model")) |value| {
            const requested = try stringList(self.arena, value) orelse &.{};
            if (requested.len == 0) {
                try self.fail("{s}.model: expected a model role or list of roles", .{path});
                return null;
            }
            const lowered = try self.arena.alloc([]const u8, requested.len);
            for (requested, lowered) |role, *out| out.* = try std.ascii.allocLowerString(self.arena, role);
            roles = lowered;
        }
        self.needs_judge = true;
        return self.withModifiers(.{ .kind = .{ .llm = .{ .question = question, .roles = roles } } }, object, path);
    }

    fn shellLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const spec = object.get("shell").?;
        bad: {
            if (spec != .object) break :bad;
            const language = spec.object.get("language") orelse break :bad;
            const kernel = spec.object.get("kernel") orelse break :bad;
            if (language != .string or kernel != .bool or spec.object.count() != 2) break :bad;
            const parsed: shell_code.Language = if (std.mem.eql(u8, language.string, "python"))
                .python
            else if (std.mem.eql(u8, language.string, "js"))
                .js
            else
                break :bad;
            return self.withModifiers(.{ .kind = .{ .shell = .{ .language = parsed, .kernel = kernel.bool } } }, object, path);
        }
        try self.fail("{s}.shell: expected {{ language: python | js, kernel: boolean }}", .{path});
        return null;
    }

    fn astLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const sources = try stringList(self.arena, object.get("ast").?) orelse &.{};
        if (sources.len == 0) {
            try self.fail("{s}.ast: expected a pattern or list of patterns", .{path});
            return null;
        }
        if (object.get("strictness")) |value| {
            if (value != .string or !isKey(&strictness_values, value.string)) {
                try self.fail("{s}.strictness: expected one of cst, smart, ast, relaxed, signature, template", .{path});
                return null;
            }
        }
        var selector: ast.Selector = .none;
        if (object.get("selector")) |value| {
            if (value != .string) {
                try self.fail("{s}.selector: expected a node kind", .{path});
                return null;
            }
            if (!std.mem.eql(u8, value.string, "predefined_type")) {
                try self.fail("{s}.selector: only predefined_type is supported, got \"{s}\"", .{ path, value.string });
                return null;
            }
            selector = .predefined_type;
        }
        const patterns = try self.arena.alloc(ast.Pattern, sources.len);
        for (sources, patterns) |source, *out| out.* = ast.compilePattern(self.arena, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.fail("{s}.ast: empty pattern", .{path});
                return null;
            },
        };
        var where: std.ArrayList(ast.Constraint) = .empty;
        if (object.get("where")) |spec| {
            if (spec != .object) {
                try self.fail("{s}.where: expected a mapping of metavariable name to constraint", .{path});
                return null;
            }
            var entries = spec.object.iterator();
            while (entries.next()) |entry| {
                const raw_name = entry.key_ptr.*;
                const name = std.mem.trim(u8, std.mem.trimStart(u8, raw_name, "$"), " ");
                if (name.len == 0) {
                    try self.fail("{s}.where: empty metavariable name", .{path});
                    return null;
                }
                var constraint: ast.Constraint = .{ .name = name };
                switch (entry.value_ptr.*) {
                    .string => |s| constraint.regex = try self.compileRegex(s, path) orelse return null,
                    .object => |o| {
                        var it = o.iterator();
                        while (it.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "regex") and !std.mem.eql(u8, field.key_ptr.*, "notRegex")) {
                            try self.fail("{s}.where.{s}: unknown key \"{s}\"", .{ path, raw_name, field.key_ptr.* });
                            return null;
                        };
                        if (o.get("regex")) |v| if (v == .string) {
                            constraint.regex = try self.compileRegex(v.string, path) orelse return null;
                        };
                        if (o.get("notRegex")) |v| if (v == .string) {
                            constraint.not_regex = try self.compileRegex(v.string, path) orelse return null;
                        };
                        if (constraint.regex == null and constraint.not_regex == null) {
                            try self.fail("{s}.where.{s}: expected regex or notRegex", .{ path, raw_name });
                            return null;
                        }
                    },
                    else => {
                        try self.fail("{s}.where.{s}: expected a regex or {{ regex, notRegex }} mapping", .{ path, raw_name });
                        return null;
                    },
                }
                try where.append(self.arena, constraint);
            }
        }
        self.needs_ast = true;
        return self.withModifiers(.{ .kind = .{ .ast = .{ .patterns = patterns, .sources = sources, .selector = selector, .where = where.items } } }, object, path);
    }

    fn regexLeaf(self: *Compiler, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        const list = try self.regexList(object.get("regex").?, try self.arena.print("{s}.regex", .{path})) orelse return null;
        var kinds: ?[]const regions.Kind = null;
        if (object.get("in")) |value| {
            const requested = try stringList(self.arena, value) orelse &.{};
            if (requested.len == 0) {
                try self.fail("{s}.in: expected one or more of any, code, comment, string, prose", .{path});
                return null;
            }
            var out: std.ArrayList(regions.Kind) = .empty;
            for (requested) |token| {
                if (std.ascii.eqlIgnoreCase(token, "any")) continue;
                const kind = std.meta.stringToEnum(regions.Kind, token) orelse {
                    try self.fail("{s}.in: expected one of any, code, comment, string, prose, got \"{s}\"", .{ path, token });
                    return null;
                };
                if (std.mem.findScalar(regions.Kind, out.items, kind) == null) try out.append(self.arena, kind);
            }
            if (out.items.len > 0) kinds = out.items;
        }
        return self.withModifiers(.{ .kind = .{ .regex = .{ .patterns = list.compiled, .sources = list.sources, .regions = kinds } } }, object, path);
    }

    fn withModifiers(self: *Compiler, base: Node, object: std.json.ObjectMap, path: []const u8) !?*const Node {
        var out = base;
        if (object.get("count")) |value| {
            const count = positiveInt(value) orelse {
                try self.fail("{s}.count: expected a positive integer", .{path});
                return null;
            };
            if (!locates(&out)) {
                try self.fail("{s}.count: only applies to regex/ast/shell conditions", .{path});
                return null;
            }
            out.count = @intCast(@min(count, std.math.maxInt(u32)));
        }
        inline for (.{ .{ "inside", "inside" }, .{ "notInside", "not_inside" }, .{ "has", "has" }, .{ "notHas", "not_has" } }) |pair| {
            if (object.get(pair[0])) |spec| {
                if (!locates(&out)) {
                    try self.fail("{s}.{s}: only applies to regex/ast/shell conditions", .{ path, pair[0] });
                    return null;
                }
                const child = try self.node(spec, try self.arena.print("{s}.{s}", .{ path, pair[0] })) orelse return null;
                if (!locates(child)) {
                    try self.fail("{s}.{s}: needs a regex/ast/shell condition, not a context test", .{ path, pair[0] });
                    return null;
                }
                @field(out, pair[1]) = child;
            }
        }
        out.cost = costOf(&out);
        return try self.make(out);
    }
};

fn positiveInt(value: Value) ?usize {
    const number: i64 = switch (value) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch return null,
        .float => |f| if (@floor(f) == f) @intFromFloat(f) else return null,
        else => return null,
    };
    if (number < 1) return null;
    return @intCast(number);
}

fn costOf(node: *const Node) u8 {
    return switch (node.kind) {
        .lang, .path, .did => cost_context,
        .regex, .shell => cost_regex,
        .ast => cost_ast,
        .llm => cost_judge,
        .not => |child| child.cost,
        .@"if" => |branch| @max(branch.guard.cost, branch.then.cost, if (branch.@"else") |e| e.cost else cost_context),
        .all, .any => |children| blk: {
            var highest: u8 = cost_context;
            for (children) |child| highest = @max(highest, child.cost);
            break :blk highest;
        },
    };
}

/// Whether a node yields located spans rather than a whole-buffer verdict.
pub fn locates(node: *const Node) bool {
    return switch (node.kind) {
        .regex, .ast, .shell => true,
        .all => |children| for (children) |child| {
            if (locates(child)) break true;
        } else false,
        .any => |children| for (children) |child| {
            if (!locates(child)) break false;
        } else true,
        .@"if" => |branch| locates(branch.then) and (branch.@"else" == null or locates(branch.@"else".?)),
        else => false,
    };
}

fn describe(arena: Allocator, out: *std.ArrayList(u8), node: *const Node) error{OutOfMemory}!void {
    switch (node.kind) {
        .regex => |leaf| {
            try out.appendSlice(arena, "regex ");
            for (leaf.sources, 0..) |source, i| {
                if (i > 0) try out.appendSlice(arena, " | ");
                try out.print(arena, "/{s}/", .{source});
            }
            if (leaf.regions) |kinds| {
                try out.appendSlice(arena, " in ");
                for (kinds, 0..) |kind, i| {
                    if (i > 0) try out.append(arena, '|');
                    try out.appendSlice(arena, @tagName(kind));
                }
            }
        },
        .ast => |leaf| {
            try out.appendSlice(arena, "ast ");
            for (leaf.sources, 0..) |source, i| {
                if (i > 0) try out.appendSlice(arena, " | ");
                try out.print(arena, "`{s}`", .{source});
            }
            if (leaf.where.len > 0) {
                try out.appendSlice(arena, " where ");
                for (leaf.where, 0..) |constraint, i| {
                    if (i > 0) try out.appendSlice(arena, ", ");
                    try out.print(arena, "${s}", .{constraint.name});
                }
            }
        },
        .shell => |leaf| try out.print(arena, "shell {s} {s}", .{ @tagName(leaf.language), if (leaf.kernel) "kernel" else "process" }),
        .lang => |langs| {
            try out.appendSlice(arena, "lang ");
            try joinInto(arena, out, langs, "|");
        },
        .path => |predicate| {
            try out.appendSlice(arena, "path ");
            try describePredicate(arena, out, predicate);
        },
        .did => |did| {
            try out.appendSlice(arena, "did");
            if (did.tools.len > 0) {
                try out.append(arena, ' ');
                try joinInto(arena, out, did.tools, "|");
            }
            if (did.path) |predicate| {
                try out.appendSlice(arena, " path ");
                try describePredicate(arena, out, predicate);
            }
            for (did.pattern_sources, 0..) |source, i| try out.print(arena, "{s}/{s}/", .{ if (i == 0) " args " else "|", source });
            if (did.within) |within| try out.print(arena, " within {d}", .{within});
        },
        .llm => |leaf| {
            try out.print(arena, "llm \"{s}\" (", .{leaf.question});
            try joinInto(arena, out, leaf.roles, "→");
            try out.append(arena, ')');
        },
        .not => |child| {
            try out.appendSlice(arena, "not ");
            try describe(arena, out, child);
        },
        .@"if" => |branch| {
            try out.appendSlice(arena, "if ");
            try describe(arena, out, branch.guard);
            try out.appendSlice(arena, " then ");
            try describe(arena, out, branch.then);
            if (branch.@"else") |otherwise| {
                try out.appendSlice(arena, " else ");
                try describe(arena, out, otherwise);
            }
        },
        .all, .any => |children| {
            try out.appendSlice(arena, @tagName(node.kind));
            try out.append(arena, '(');
            for (children, 0..) |child, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try describe(arena, out, child);
            }
            try out.append(arena, ')');
        },
    }
    var first = true;
    if (node.count > 1) {
        try out.print(arena, " (count≥{d}", .{node.count});
        first = false;
    }
    inline for (.{ .{ "inside", "inside" }, .{ "notInside", "not_inside" }, .{ "has", "has" }, .{ "notHas", "not_has" } }) |pair| {
        if (@field(node, pair[1])) |child| {
            try out.appendSlice(arena, if (first) " (" else ", ");
            first = false;
            try out.print(arena, "{s} ", .{pair[0]});
            try describe(arena, out, child);
        }
    }
    if (!first) try out.append(arena, ')');
}

fn describePredicate(arena: Allocator, out: *std.ArrayList(u8), predicate: PathPredicate) !void {
    var parts: usize = 0;
    if (predicate.globs.len > 0) {
        try joinInto(arena, out, predicate.globs, "|");
        parts += 1;
    }
    if (predicate.pattern_sources.len > 0) {
        if (parts > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, "matching ");
        for (predicate.pattern_sources, 0..) |source, i| try out.print(arena, "{s}/{s}/", .{ if (i == 0) "" else "|", source });
        parts += 1;
    }
    inline for (.{ "under", "outside" }) |key| {
        if (@field(predicate, key).len > 0) {
            if (parts > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, key ++ " ");
            try joinInto(arena, out, @field(predicate, key), "|");
            parts += 1;
        }
    }
}

fn joinInto(arena: Allocator, out: *std.ArrayList(u8), items: []const []const u8, sep: []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(arena, sep);
        try out.appendSlice(arena, item);
    }
}

const min_literal = 3;

/// The longest top-level literal run every match must contain.
fn longestRegexLiteral(source: []const u8) ?[]const u8 {
    var body = source;
    if (std.mem.startsWith(u8, body, "(?")) if (std.mem.findScalar(u8, body, ')')) |close| {
        var flags = true;
        for (body[2..close]) |c| if (!std.ascii.isLower(c)) {
            flags = false;
        };
        if (flags and close > 2) {
            if (std.mem.findScalar(u8, body[2..close], 'i') != null) return null;
            body = body[close + 1 ..];
        }
    };
    var best: ?[]const u8 = null;
    var run_start: usize = 0;
    var run_len: usize = 0;
    var depth: usize = 0;
    var in_class = false;
    var index: usize = 0;
    const Flush = struct {
        fn apply(b: *?[]const u8, text: []const u8, start: usize, len: usize, optional_tail: bool) void {
            const length = if (optional_tail and len > 0) len - 1 else len;
            if (length >= min_literal and (b.* == null or length > b.*.?.len)) b.* = text[start .. start + length];
        }
    };
    while (index < body.len) : (index += 1) {
        const c = body[index];
        if (c == '\\') {
            Flush.apply(&best, body, run_start, run_len, false);
            run_len = 0;
            index += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => {
                Flush.apply(&best, body, run_start, run_len, false);
                run_len = 0;
                in_class = true;
            },
            '(' => {
                Flush.apply(&best, body, run_start, run_len, false);
                run_len = 0;
                depth += 1;
            },
            ')' => depth -|= 1,
            else => {
                if (depth > 0) continue;
                if (c == '|') return null;
                if (c == '?' or c == '*' or std.mem.startsWith(u8, body[index..], "{0")) {
                    Flush.apply(&best, body, run_start, run_len, true);
                    run_len = 0;
                    continue;
                }
                if (std.ascii.isAlphanumeric(c) or c == '_') {
                    if (run_len == 0) run_start = index;
                    run_len += 1;
                    continue;
                }
                Flush.apply(&best, body, run_start, run_len, false);
                run_len = 0;
            },
        }
    }
    Flush.apply(&best, body, run_start, run_len, false);
    return best;
}

fn literalsOf(arena: Allocator, node: *const Node) error{OutOfMemory}![]const []const u8 {
    switch (node.kind) {
        .regex => |leaf| {
            var out: std.ArrayList([]const u8) = .empty;
            for (leaf.patterns, leaf.sources) |pattern, source| {
                if (pattern.flags.ignore_case) return &.{};
                try out.append(arena, longestRegexLiteral(source) orelse return &.{});
            }
            return out.items;
        },
        .ast => |leaf| {
            if (leaf.selector != .none) return &.{};
            var out: std.ArrayList([]const u8) = .empty;
            for (leaf.patterns) |pattern| try out.append(arena, ast.longestLiteral(pattern) orelse return &.{});
            return out.items;
        },
        .all => |children| return requiredLiterals(arena, children, literalsOf),
        .any => |children| return alternativeLiterals(arena, children, literalsOf),
        .@"if" => |branch| {
            if (branch.@"else") |otherwise| return alternativeLiterals(arena, &.{ branch.then, otherwise }, literalsOf);
            return requiredLiterals(arena, &.{ branch.guard, branch.then }, literalsOf);
        },
        else => return &.{},
    }
}

const LiteralFn = fn (Allocator, *const Node) error{OutOfMemory}![]const []const u8;

fn shortest(literals: []const []const u8) usize {
    var min: usize = std.math.maxInt(usize);
    for (literals) |literal| min = @min(min, literal.len);
    return min;
}

fn requiredLiterals(arena: Allocator, nodes: []const *const Node, comptime f: LiteralFn) ![]const []const u8 {
    var best: []const []const u8 = &.{};
    for (nodes) |child| {
        const literals = try f(arena, child);
        if (literals.len == 0) continue;
        if (best.len == 0 or shortest(literals) > shortest(best)) best = literals;
    }
    return best;
}

fn alternativeLiterals(arena: Allocator, nodes: []const *const Node, comptime f: LiteralFn) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (nodes) |child| {
        const literals = try f(arena, child);
        if (literals.len == 0) return &.{};
        try out.appendSlice(arena, literals);
    }
    return out.items;
}

/// Regex sources that are plain literals, so a delta scan for them is
/// exact; the stream prefilter uses these, as proto's manager does.
fn incrementalLiteralsOf(arena: Allocator, node: *const Node) error{OutOfMemory}![]const []const u8 {
    switch (node.kind) {
        .regex => |leaf| {
            for (leaf.patterns, leaf.sources) |pattern, source| {
                if (pattern.flags.ignore_case or source.len == 0) return &.{};
                for (source) |c| if (std.mem.findScalar(u8, "\\^$.*+?()[]{}|", c) != null) return &.{};
            }
            return leaf.sources;
        },
        .all => |children| return requiredLiterals(arena, children, incrementalLiteralsOf),
        .any => |children| return alternativeLiterals(arena, children, incrementalLiteralsOf),
        .@"if" => |branch| {
            if (branch.@"else") |otherwise| return alternativeLiterals(arena, &.{ branch.then, otherwise }, incrementalLiteralsOf);
            return requiredLiterals(arena, &.{ branch.guard, branch.then }, incrementalLiteralsOf);
        },
        else => return &.{},
    }
}

/// Cheap bulk pre-check: false means the program cannot match `text`.
pub fn mayMatch(program: Program, text: []const u8) bool {
    if (program.literals.len == 0) return true;
    for (program.literals) |literal| if (std.mem.find(u8, text, literal) != null) return true;
    return false;
}
