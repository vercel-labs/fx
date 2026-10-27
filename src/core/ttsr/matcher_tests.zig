//! Tests for every `match:` leaf, operator and modifier, ported from
//! proto's `ttsr-matcher.test.ts`.
const std = @import("std");
const yaml = @import("yaml.zig");
const matcher = @import("matcher.zig");
const evaluate = @import("evaluate.zig");

const Input = evaluate.Input;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
    }

    fn program(self: *Fixture, spec_yaml: []const u8) !matcher.Program {
        const arena = self.arena_state.allocator();
        const doc = try yaml.parse(arena, spec_yaml);
        const compiled = try matcher.compile(arena, doc.object.get("match").?);
        if (compiled.program == null) {
            for (compiled.errors) |err| std.debug.print("compile error: {s}\n", .{err});
            return error.TestCompileFailed;
        }
        return compiled.program.?;
    }

    fn errors(self: *Fixture, spec_yaml: []const u8) ![]const []const u8 {
        const arena = self.arena_state.allocator();
        const doc = try yaml.parse(arena, spec_yaml);
        const compiled = try matcher.compile(arena, doc.object.get("match").?);
        try std.testing.expect(compiled.program == null);
        return compiled.errors;
    }

    fn run(self: *Fixture, spec_yaml: []const u8, input: Input) !?evaluate.Evidence {
        const p = try self.program(spec_yaml);
        var ctx = evaluate.Context.init(self.arena_state.allocator(), input);
        return evaluate.evaluate(p, &ctx);
    }
};

const ts_file =
    \\// never write `as any`
    \\const label = "as any";
    \\const value = input as any;
;

test "a regex constrained to code ignores comments and strings" {
    var f = Fixture.init();
    defer f.deinit();
    const tool: Input = .{ .text = ts_file, .source = .tool, .file_paths = &.{"src/a.ts"} };
    const evidence = (try f.run("match: { regex: '\\bas any\\b', in: code }", tool)).?;
    try std.testing.expectEqual(@as(usize, 1), evidence.snippets.len);
    try std.testing.expectEqual(@as(usize, 3), evidence.snippets[0].line);
    try std.testing.expectEqualStrings("const value = input as any;", evidence.snippets[0].text);
    try std.testing.expect((try f.run("match: { regex: '\\bas any\\b', in: [comment] }", tool)) != null);
    try std.testing.expect((try f.run("match: { regex: '\\bas any\\b', in: [string] }", tool)) != null);
    // Unclassifiable buffers fail closed.
    try std.testing.expect((try f.run("match: { regex: 'as any', in: code }", .{ .text = ts_file, .source = .tool, .file_paths = &.{"a.unknown"} })) == null);
    // Prose: only fenced blocks are code.
    const prose = "Avoid `as any`.\n```ts\nx as any\n```";
    const fenced = (try f.run("match: { regex: 'as any', in: code }", .{ .text = prose, .source = .text })).?;
    try std.testing.expectEqual(@as(usize, 3), fenced.snippets[0].line);
    try std.testing.expect((try f.run("match: { regex: 'as any', in: prose }", .{ .text = prose, .source = .text })) != null);
}

test "lang path and context tests gate by the tool call's target" {
    var f = Fixture.init();
    defer f.deinit();
    const spec = "match: { all: [ { lang: [go] }, { regex: 'ioutil' } ] }";
    try std.testing.expect((try f.run(spec, .{ .text = "import \"io/ioutil\"", .source = .tool, .file_paths = &.{"main.go"} })) != null);
    try std.testing.expect((try f.run(spec, .{ .text = "import \"io/ioutil\"", .source = .tool, .file_paths = &.{"main.ts"} })) == null);
    const path_spec = "match: { all: [ { path: 'src/**/*.ts' }, { regex: 'x' } ] }";
    try std.testing.expect((try f.run(path_spec, .{ .text = "x", .source = .tool, .file_paths = &.{"./src/deep/a.ts"}, .cwd = "/w" })) != null);
    try std.testing.expect((try f.run(path_spec, .{ .text = "x", .source = .tool, .file_paths = &.{"lib/a.ts"}, .cwd = "/w" })) == null);
    const under = "match: { all: [ { path: { outside: cwd } }, { regex: 'x' } ] }";
    try std.testing.expect((try f.run(under, .{ .text = "x", .source = .tool, .file_paths = &.{"/etc/hosts"}, .cwd = "/w" })) != null);
    try std.testing.expect((try f.run(under, .{ .text = "x", .source = .tool, .file_paths = &.{"a/b"}, .cwd = "/w" })) == null);
    const by_regex = "match: { all: [ { path: { regex: '\\.lock$', under: '~' } }, { regex: 'x' } ] }";
    try std.testing.expect((try f.run(by_regex, .{ .text = "x", .source = .tool, .file_paths = &.{"~/p/bun.lock"}, .cwd = "/w", .home = "/home/me" })) != null);
}

test "operators combine leaves: all any not and if then else" {
    var f = Fixture.init();
    defer f.deinit();
    const text: Input = .{ .text = "alpha beta", .source = .text };
    try std.testing.expect((try f.run("match: { all: [alpha, beta] }", text)) != null);
    try std.testing.expect((try f.run("match: { all: [alpha, gamma] }", text)) == null);
    try std.testing.expect((try f.run("match: [gamma, beta]", text)) != null);
    try std.testing.expect((try f.run("match: { all: [ alpha, { not: gamma } ] }", text)) != null);
    try std.testing.expect((try f.run("match: { not: alpha }", text)) == null);
    const branch =
        \\match:
        \\  if: { lang: [rs] }
        \\  then: { regex: 'Box::leak', in: code }
        \\  else: { regex: 'Box::leak' }
    ;
    const rust_comment: Input = .{ .text = "// Box::leak", .source = .tool, .file_paths = &.{"a.rs"} };
    try std.testing.expect((try f.run(branch, rust_comment)) == null);
    try std.testing.expect((try f.run(branch, .{ .text = "// Box::leak", .source = .tool, .file_paths = &.{"a.md"} })) != null);
    try std.testing.expect((try f.run("match: { if: { lang: [go] }, then: alpha }", text)) == null);
}

test "modifiers filter located spans: count inside notInside has notHas" {
    var f = Fixture.init();
    defer f.deinit();
    const text: Input = .{ .text = "foo(a) foo(b) bar(foo)", .source = .text };
    try std.testing.expect((try f.run("match: { regex: 'foo\\(', count: 2 }", text)) != null);
    try std.testing.expect((try f.run("match: { regex: 'foo\\(', count: 3 }", text)) == null);
    try std.testing.expect((try f.run("match: { regex: 'foo', inside: { regex: 'bar\\([^)]*\\)' } }", text)) != null);
    try std.testing.expect((try f.run("match: { regex: 'foo', notInside: { regex: 'bar\\([^)]*\\)' }, count: 2 }", text)) != null);
    try std.testing.expect((try f.run("match: { regex: 'foo', notInside: { regex: 'bar\\([^)]*\\)' }, count: 3 }", text)) == null);
    try std.testing.expect((try f.run("match: { regex: 'foo\\(.\\)', has: { regex: 'b' } }", text)) != null);
    try std.testing.expect((try f.run("match: { regex: 'foo\\(.\\)', notHas: { regex: '[ab]' } }", text)) == null);
}

test "ast leaves settle only on settled buffers" {
    var f = Fixture.init();
    defer f.deinit();
    const spec = "match: { all: [ { lang: [go] }, { ast: 'for $I := 0; $I < $N; $I++ { $$$BODY }' } ] }";
    const source = "func f() {\n\tfor i := 0; i < n; i++ {\n\t\tuse(i)\n\t}\n}";
    try std.testing.expect((try f.run(spec, .{ .text = source, .source = .tool, .file_paths = &.{"a.go"} })) == null);
    const evidence = (try f.run(spec, .{ .text = source, .source = .tool, .file_paths = &.{"a.go"}, .settled = true })).?;
    try std.testing.expectEqual(@as(usize, 2), evidence.snippets[0].line);
    const where =
        \\match:
        \\  ast: "try { $$$BODY } catch ($E) { $$$HANDLER }"
        \\  where:
        \\    E: "^_"
    ;
    try std.testing.expect((try f.run(where, .{ .text = "try { a() } catch (_e) {}", .source = .tool, .file_paths = &.{"a.ts"}, .settled = true })) != null);
    try std.testing.expect((try f.run(where, .{ .text = "try { a() } catch (e) {}", .source = .tool, .file_paths = &.{"a.ts"}, .settled = true })) == null);
    // An unresolved `not: { ast }` never reads as satisfied.
    try std.testing.expect((try f.run("match: { not: { ast: 'x' } }", .{ .text = "y", .source = .tool, .file_paths = &.{"a.ts"} })) == null);
}

test "shell leaves find interpreter cells in shell commands" {
    var f = Fixture.init();
    defer f.deinit();
    const spec = "match: { shell: { language: python, kernel: false } }";
    try std.testing.expect((try f.run(spec, .{ .text = "python3 -c 'print(1)'", .source = .tool, .lang = "bash" })) != null);
    try std.testing.expect((try f.run(spec, .{ .text = "python3 script.py", .source = .tool, .lang = "bash" })) == null);
    try std.testing.expect((try f.run(spec, .{ .text = "python3 -c 'print(1)'", .source = .tool, .file_paths = &.{"a.py"} })) == null);
}

test "did leaves test the session's earlier tool calls" {
    var f = Fixture.init();
    defer f.deinit();
    const history = [_]evaluate.ToolCallRecord{
        .{ .name = "read_file", .paths = &.{"skill://rust/SKILL.md"}, .args = "{\"path\":\"skill://rust/SKILL.md\"}" },
        .{ .name = "shell", .args = "{\"command\":\"cargo test\"}" },
    };
    const base: Input = .{ .text = "fn main() {}", .source = .tool, .cwd = "/w", .history = &history };
    try std.testing.expect((try f.run("match: { all: [ { did: read_file }, fn ] }", base)) != null);
    try std.testing.expect((try f.run("match: { all: [ { not: { did: { tool: read_file, path: 'skill://rust/**' } } }, fn ] }", base)) == null);
    try std.testing.expect((try f.run("match: { all: [ { did: { args: 'cargo test', within: 1 } }, fn ] }", base)) != null);
    try std.testing.expect((try f.run("match: { all: [ { did: { tool: read_file, within: 1 } }, fn ] }", base)) == null);
    var no_history = base;
    no_history.history = &.{};
    try std.testing.expect((try f.run("match: { all: [ { not: { did: shell } }, fn ] }", no_history)) != null);
}

const FakeJudge = struct {
    answer: ?bool,
    calls: usize = 0,

    fn ask(raw: *anyopaque, request: evaluate.JudgeRequest) ?bool {
        const self: *FakeJudge = @ptrCast(@alignCast(raw));
        self.calls += 1;
        std.debug.assert(request.question.len > 0);
        return self.answer;
    }
};

test "llm leaves ask the judge only on settled buffers and after cheaper leaves" {
    var f = Fixture.init();
    defer f.deinit();
    var judge: FakeJudge = .{ .answer = true };
    const spec = "match: { all: [ { llm: 'Is this a real cast?' }, { regex: 'as any' } ] }";
    const settled: Input = .{ .text = "x as any", .source = .text, .settled = true, .judge = .{ .ctx = &judge, .ask = FakeJudge.ask } };
    try std.testing.expect((try f.run(spec, settled)) != null);
    try std.testing.expectEqual(@as(usize, 1), judge.calls);
    var streaming = settled;
    streaming.settled = false;
    try std.testing.expect((try f.run(spec, streaming)) == null);
    var cheap_miss = settled;
    cheap_miss.text = "nothing";
    try std.testing.expect((try f.run(spec, cheap_miss)) == null);
    try std.testing.expectEqual(@as(usize, 1), judge.calls);
    judge.answer = null;
    try std.testing.expect((try f.run(spec, settled)) == null);
    var no_judge = settled;
    no_judge.judge = null;
    try std.testing.expect((try f.run(spec, no_judge)) == null);
}

test "compile errors name the offending path" {
    var f = Fixture.init();
    defer f.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "match: { regex: '(' }", "invalid regex" },
        .{ "match: { regex: a, lang: go }", "conflicting keys" },
        .{ "match: { bogus: 1 }", "needs one of" },
        .{ "match: { regex: a, then: b }", "only applies to if" },
        .{ "match: { lang: go, count: 2 }", "only applies to regex/ast/shell" },
        .{ "match: { regex: a, inside: { lang: go } }", "not a context test" },
        .{ "match: { if: { lang: go } }", "needs a then: branch" },
        .{ "match: { shell: { language: ruby, kernel: true } }", "expected { language" },
        .{ "match: { ast: x, selector: call_expression }", "only predefined_type" },
        .{ "match: { did: { within: 0, tool: x } }", "positive integer" },
        .{ "match: { regex: a, in: [nowhere] }", "got \"nowhere\"" },
        .{ "match: { all: [] }", "at least one condition" },
    };
    for (cases) |case| {
        const errors = try f.errors(case[0]);
        try std.testing.expect(errors.len > 0);
        if (std.mem.find(u8, errors[0], case[1]) == null) {
            std.debug.print("expected '{s}' in '{s}'\n", .{ case[1], errors[0] });
            return error.TestUnexpectedError;
        }
    }
}

test "descriptions and literal prefilters" {
    var f = Fixture.init();
    defer f.deinit();
    const program = try f.program("match: { if: { lang: [rs] }, then: { regex: 'Box::leak', in: code }, else: { all: [ { regex: 'Box::leak' }, { llm: 'Real?' } ] } }");
    try std.testing.expectEqualStrings("if lang rs then regex /Box::leak/ in code else all(regex /Box::leak/, llm \"Real?\" (tiny→smol))", program.description);
    try std.testing.expect(program.needs_judge);
    try std.testing.expect(matcher.mayMatch(program, "let b = Box::leak(x)"));
    try std.testing.expect(!matcher.mayMatch(program, "nothing here"));
    try std.testing.expectEqual(@as(usize, 2), program.incremental_literals.len);
    const alternated = try f.program("match: { regex: 'foo|bar' }");
    try std.testing.expectEqual(@as(usize, 0), alternated.literals.len);
    const optional = try f.program("match: { regex: 'colou?r_name' }");
    try std.testing.expectEqualStrings("r_name", optional.literals[0]);
    const legacy = try matcher.compileLegacy(f.arena_state.allocator(), &.{ "good", "(bad" }, &.{});
    try std.testing.expect(legacy.program != null);
    try std.testing.expectEqual(@as(usize, 1), legacy.errors.len);
}
