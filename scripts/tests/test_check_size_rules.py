from __future__ import annotations

import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout

from scripts import check_size_rules


MACOS = "SIZE_CEILING_MIB = 7.250\n"
LINUX = """\
ARM64 = Platform(
    TARGET="aarch64-linux",
    SIZE_CEILING_MIB=7.500,
)
X86_64 = Platform(
    TARGET="x86_64-linux",
    SIZE_CEILING_MIB=9.500,
)
"""
CORPUS = {
    "version": 1,
    "intentional_exclusions": {"excluded.test.ts": "live network"},
    "scenarios": [{"name": "help", "env_set": {"FX_TEST_SKIP_ONBOARDING": "1"}}],
}
SHARED_BODY = """\
    const total = left.len + right.len;
    if (total > limit) return error.TooLong;
    return total * 2 + offset;
"""


def function(name: str, body_lines: int, prefix: str = "") -> str:
    body = "".join(f"    _ = {index};\n" for index in range(body_lines))
    return f"{prefix}fn {name}() void {{\n{body}}}\n"


class CheckSizeRulesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.write("scripts/pgso/macos.py", MACOS)
        self.write("scripts/pgso/linux.py", LINUX)
        self.write("scripts/pgso/corpus.json", json.dumps(CORPUS))
        self.write("tests/e2e/hooks.test.ts", 'env.FX_TEST_USED = "1";\n')
        self.write("tests/e2e/excluded.test.ts", 'env.FX_TEST_EXCLUDED_ONLY = "1";\n')
        self.write(
            "src/app.zig",
            'const helper = @import("helper.zig");\n'
            + function("short", 3)
            + 'test "test blocks are ignored" {\n'
            + "    std.mem.sort(u8, &.{}, {}, lessThan);\n"
            + "".join(f"    _ = {index};\n" for index in range(400))
            + "}\n",
        )
        self.write_baseline()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def write_baseline(self) -> None:
        with redirect_stdout(io.StringIO()):
            self.assertEqual(check_size_rules.main(["--root", str(self.root), "--write-baseline"]), 0)

    def check(self) -> tuple[list[str], list[str]]:
        problems, notes = check_size_rules.Checker(self.root).compare(
            json.loads((self.root / check_size_rules.BASELINE).read_text())
        )
        return [problem.check for problem in problems], notes

    def test_clean_tree_passes_and_test_blocks_are_ignored(self) -> None:
        self.assertEqual(self.check(), ([], []))
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(check_size_rules.main(["--root", str(self.root)]), 0)
        self.assertIn("size rules: ok", output.getvalue())

    def test_new_long_function_fails_and_recorded_one_may_not_grow(self) -> None:
        self.write("src/long.zig", function("long", 310))
        self.assertEqual(self.check()[0], ["long-fns"])
        self.write_baseline()
        self.assertEqual(self.check(), ([], []))
        self.write("src/long.zig", function("long", 320))
        self.assertEqual(self.check()[0], ["long-fns"])
        self.write("src/long.zig", function("long", 305))
        problems, notes = self.check()
        self.assertEqual(problems, [])
        self.assertEqual(len(notes), 1)

    def test_one_line_bodies_end_their_function(self) -> None:
        self.write("src/one_line.zig", "inline fn tiny() void {}\nfn small() u8 { return 1; }\n" + function("next", 290))
        self.write_baseline()
        recorded = json.loads((self.root / check_size_rules.BASELINE).read_text())
        self.assertEqual(recorded["long_functions"], {})

    def test_functions_returning_type_are_read_member_by_member(self) -> None:
        members = function("first", 200, "    pub ") + function("second", 200, "    pub ")
        self.write("src/factory.zig", f"pub fn Runtime(comptime T: type) type {{\n    return struct {{\n{members}    }};\n}}\n")
        self.assertEqual(self.check()[0], [])

    def test_new_inline_fn_fails(self) -> None:
        self.write("src/app.zig", (self.root / "src/app.zig").read_text() + "inline fn tiny() void {}\n")
        self.assertEqual(self.check()[0], ["inline"])

    def test_std_sort_and_typed_json_parse_fail_outside_std_only_modules(self) -> None:
        importing = 'const helper = @import("helper.zig");\n'
        self.write("src/sorter.zig", importing + "fn f() void {\n    std.mem.sort(u8, items, {}, lessThan);\n}\n")
        self.write(
            "src/parser.zig",
            importing
            + "fn f() void {\n    _ = std.json.parseFromSlice(\n        Config,\n        alloc,\n        text,\n        .{},\n    );\n"
            + "    _ = std.json.parseFromSlice(std.json.Value, alloc, text, .{});\n}\n",
        )
        self.assertEqual(sorted(self.check()[0]), ["std-generic", "std-generic"])
        self.write("src/parser.zig", importing + "fn f() void {\n    _ = std.json.parseFromSlice(std.json.Value, alloc, text, .{});\n}\n")
        self.write("src/core/indexer/walk.zig", importing + "fn f() void {\n    std.mem.sort(u8, items, {}, lessThan);\n}\n")
        self.write("src/std_only.zig", 'const std = @import("std");\nfn f() void {\n    std.mem.sort(u8, items, {}, lessThan);\n}\n')
        self.write("src/sorter.zig", importing)
        self.assertEqual(self.check()[0], [])

    def test_trace_in_a_loop_fails_unless_a_reason_is_given(self) -> None:
        def traced(body: str) -> str:
            return f"fn f() void {{\n{body}}}\n"

        self.write("src/trace.zig", traced('    for (items) |item| {\n        debug_trace.logf("x", "{d}", .{item});\n    }\n'))
        self.assertEqual(self.check()[0], ["trace-loops"])
        self.write("src/trace.zig", traced('    for (items) |item| debug_trace.logf("x", "{d}", .{item});\n'))
        self.assertEqual(self.check()[0], ["trace-loops"])
        self.write("src/trace.zig", traced('    while (attempt < 3) : (attempt += 1)\n        debug_trace.logf("x", "retry", .{});\n'))
        self.assertEqual(self.check()[0], ["trace-loops"])
        self.write(
            "src/trace.zig",
            traced(
                "    while (attempt < 3) : (attempt += 1) {\n"
                "        // trace: once per retry, at most three\n"
                '        debug_trace.logf("x", "retry", .{});\n'
                "    }\n"
                "    for (.{ a, b }) |item| {\n        _ = item;\n    }\n"
                '    debug_trace.logf("x", "done", .{});\n'
            ),
        )
        self.assertEqual(self.check()[0], [])

    def test_same_body_in_two_files_fails_until_recorded(self) -> None:
        self.write("src/one.zig", f"fn first(left: []const u8, right: []const u8) !usize {{\n{SHARED_BODY}}}\n")
        self.write("src/two.zig", f"pub fn second(left: []const u8, right: []const u8) !usize {{\n{SHARED_BODY}}}\n")
        self.assertEqual(self.check()[0], ["same-body"])
        self.write_baseline()
        self.assertEqual(self.check()[0], [])
        self.write("src/three.zig", f"fn third(left: []const u8, right: []const u8) !usize {{\n{SHARED_BODY}}}\n")
        self.assertEqual(self.check()[0], ["same-body"])

    def test_short_bodies_and_copies_in_one_file_are_not_flagged(self) -> None:
        self.write("src/one.zig", "fn a() u8 {\n    return 1;\n}\n")
        self.write("src/two.zig", "fn b() u8 {\n    return 1;\n}\n")
        self.write("src/same.zig", f"fn x() !usize {{\n{SHARED_BODY}}}\nfn y() !usize {{\n{SHARED_BODY}}}\n")
        self.assertEqual(self.check()[0], [])

    def test_changed_ceiling_fails(self) -> None:
        self.write("scripts/pgso/macos.py", "SIZE_CEILING_MIB = 7.500\n")
        self.assertEqual(self.check()[0], ["ceilings"])

    def test_shipped_hook_needs_a_binary_level_test(self) -> None:
        self.write("src/hooks.zig", 'fn f() void {\n    _ = io_mod.getenv("FX_TEST_USED");\n    _ = io_mod.getenv("FX_TEST_SKIP_ONBOARDING");\n}\n')
        self.assertEqual(self.check()[0], [])
        self.write("src/hooks.zig", 'fn f() void {\n    _ = io_mod.getenv("FX_TEST_EXCLUDED_ONLY");\n}\n')
        self.assertEqual(self.check()[0], ["test-hooks"])
        self.write("src/hooks.zig", 'fn f() void {\n    // "FX_TEST_IN_A_COMMENT"\n}\n')
        self.assertEqual(self.check()[0], [])

    def test_main_reports_problems_with_exit_one(self) -> None:
        self.write("src/long.zig", function("long", 310))
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(check_size_rules.main(["--root", str(self.root)]), 1)
        self.assertIn("src/long.zig:1: [long-fns] long is 312 lines, over 300; split it (R6.11)", output.getvalue())


class SizeGateTests(unittest.TestCase):
    def gate(self, growth: int, body: str = "", labels: tuple[str, ...] = (), approved_by: str = "") -> list[str]:
        report = {"section_deltas_bytes": {"__TEXT.__text": growth}}
        return check_size_rules.size_gate(report, body, list(labels), approved_by)

    def test_growth_under_one_page_passes(self) -> None:
        self.assertEqual(self.gate(16 * 1024 - 1), [])
        self.assertEqual(self.gate(-200_000), [])

    def test_one_page_needs_a_size_section(self) -> None:
        self.assertEqual(len(self.gate(16 * 1024)), 1)
        self.assertEqual(len(self.gate(16 * 1024, "## Size\n")), 1)
        self.assertEqual(self.gate(16 * 1024, "## Summary\nx\n\n## Size\n\nAdds the toolbox catalog.\n"), [])

    def test_fifty_kilobytes_also_needs_the_label_from_the_approver(self) -> None:
        body = "## Size\nAdds the toolbox catalog.\n"
        labels = ("type: feature", "size: approved")
        self.assertEqual(len(self.gate(50 * 1024, body)), 1)
        self.assertEqual(self.gate(50 * 1024, body, labels, "fazxes"), [])
        self.assertEqual(len(self.gate(50 * 1024, body, labels, "someone-else")), 1)
        self.assertEqual(len(self.gate(50 * 1024, body, ("type: feature",), "fazxes")), 1)
        self.assertEqual(len(self.gate(50 * 1024, "", labels, "fazxes")), 1)

    def test_cli_prints_errors_and_exits_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = pathlib.Path(tmp, "report.json")
            body = pathlib.Path(tmp, "body.md")
            report.write_text(json.dumps({"section_deltas_bytes": {"__TEXT.__text": 60_000}}))
            body.write_text("")
            output = io.StringIO()
            with redirect_stdout(output):
                code = check_size_rules.main(
                    ["size-gate", "--report", str(report), "--body-file", str(body), "--labels", "type: bug"]
                )
            self.assertEqual(code, 1)
            self.assertEqual(output.getvalue().count("::error title=Binary size rule::"), 2)


if __name__ == "__main__":
    unittest.main()
