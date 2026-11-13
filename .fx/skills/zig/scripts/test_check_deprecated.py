"""Contract tests for check_deprecated.py. Run: python3 -m unittest discover -s scripts"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_deprecated.py")


def scan(source, *extra, timeout=60):
    with tempfile.TemporaryDirectory() as root:
        path = os.path.join(root, "sample.zig")
        with open(path, "w", encoding="utf-8") as f:
            f.write(source)
        r = subprocess.run([sys.executable, SCRIPT, *extra, root], capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout


def run_on(*paths):
    return subprocess.run([sys.executable, SCRIPT, *paths], capture_output=True, text=True, timeout=60)


class FindsDeprecatedApis(unittest.TestCase):
    def assertFlags(self, source, needle):
        code, out = scan(source)
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)

    def test_formatting(self):
        self.assertFlags('const std = @import("std");\nfn f(a: std.mem.Allocator) ![]u8 { return std.fmt.allocPrint(a, "x", .{}); }\n', "Allocator.print")
        self.assertFlags('const std = @import("std");\nfn f(b: []u8) ![]u8 { return std.fmt.bufPrint(b, "x", .{}); }\n', "std.mem.print")

    def test_search_and_copy(self):
        self.assertFlags('const std = @import("std");\nconst i = std.mem.indexOfScalar(u8, "ab", 98);\n', "findScalar")
        self.assertFlags('const std = @import("std");\nconst i = std.mem.lastIndexOf(u8, "ab", "b");\n', "findLast")
        self.assertFlags('const std = @import("std");\nfn f(d: []u8, s: []const u8) void { std.mem.copyForwards(u8, d, s); }\n', "@memmove")

    def test_filesystem_and_target(self):
        self.assertFlags('const std = @import("std");\nconst sep = std.fs.path.sep;\n', "std.Io.Dir.path")
        self.assertFlags('const builtin = @import("builtin");\nconst mac = builtin.os.tag == .macos;\n', "builtin.target.os")
        self.assertFlags('const builtin = @import("builtin");\nconst m = builtin.mode;\n', "builtin.optimize")
        self.assertFlags('const std = @import("std");\nconst O = std.builtin.AtomicOrder;\n', "std.lang")

    def test_builtins_and_containers(self):
        self.assertFlags("const E = enum(u8) { a };\nconst x = @intFromEnum(E.a);\n", "@backingInt")
        self.assertFlags('const std = @import("std");\nvar l: std.ArrayListUnmanaged(u8) = .empty;\n', "std.ArrayList")
        self.assertFlags('const std = @import("std");\nfn f(l: std.ArrayList(u8)) u8 { return l.getLast(); }\n', "last()")
        self.assertFlags('const std = @import("std");\nconst c = std.unicode.utf8Decode("a");\n', "utf8Decode")

    def test_removed_syntax(self):
        self.assertFlags('const s = "ab" ** 3;\n', "@splat")
        self.assertFlags("const a = [_]u8{0} ** 4;\n", "@splat")
        self.assertFlags("const b = .{ 1, 2 } ** 3;\n", "@splat")
        self.assertFlags("fn f() !void {\n    errdefer |err| _ = err;\n}\n", "errdefer capture")
        self.assertFlags("const v = void{};\n", "{}")

    def test_call_right_after_a_range(self):
        # Observed miss: `..` before `std` looked like field access.
        self.assertFlags('const std = @import("std");\nfn f(s: []const u8) []const u8 { return s[0..std.mem.lastIndexOfScalar(u8, s, 47).?]; }\n', "findScalarLast")

    def test_i0_only_as_a_type(self):
        self.assertFlags("const x: i0 = 0;\n", "u0")
        code, out = scan("const i0: u8 = 1;\nconst j = i0 + 1;\n")
        self.assertEqual(code, 0, out)

    def test_aliases(self):
        self.assertFlags('const std = @import("std");\nconst mem = std.mem;\nconst i = mem.indexOf(u8, "ab", "b");\n', "find")
        self.assertFlags('const native = @import("builtin");\nconst linux = native.os.tag == .linux;\n', "native.target.os")
        self.assertFlags('const std = @import("std");\nconst fmt = std.fmt;\nfn f(b: []u8) ![]u8 { return fmt.bufPrint(b, "x", .{}); }\n', "std.mem.print")


class SameLineRules(unittest.TestCase):
    def test_debug_tag_needs_an_optimize_word_after_it(self):
        code, out = scan("const strip = b.option(bool, \"s\", \"\") orelse (mode == .Debug); // optimize\n")
        self.assertEqual(code, 1, out)
        self.assertIn("Debug/ReleaseSafe", out)
        code, out = scan("const optimize = 1;\nconst e = .Debug;\n")
        self.assertEqual(code, 0, out)

    def test_linkage_word_after_the_tag(self):
        code, out = scan("comptime { @export(&f, .{ .name = \"f\", .linkage = .internal }); }\nfn f() void {}\n")
        self.assertEqual(code, 0, out)
        code, out = scan("comptime { @export(&f, .{ .name = \"f\", .visibility = .internal, .x = linkage }); }\nfn f() void {}\n")
        self.assertEqual(code, 1, out)


class ValidCodeIsNotFlagged(unittest.TestCase):
    def test_double_pointer_types_are_not_array_repetition(self):
        # Observed: `[]**u8` and `fn get() **u8` were reported as removed `**`.
        source = (
            "fn get() **u8 {\n    return undefined;\n}\n"
            "const T = []**u8;\n"
            "const O = ?**u8;\n"
            "fn f(p: **const u8) void {\n    _ = p;\n}\n"
            "const A = [2]**u8;\n"
        )
        code, out = scan(source)
        self.assertEqual(code, 0, out)


class InputItCannotTrust(unittest.TestCase):
    def test_a_missing_path_is_an_error(self):
        with tempfile.TemporaryDirectory() as root:
            r = run_on(os.path.join(root, "missing"))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("missing", r.stderr)
        self.assertIn("1 could not be read", r.stdout)

    def test_links_and_fifos_in_a_tree_are_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            tree, outside = os.path.join(root, "tree"), os.path.join(root, "outside")
            os.makedirs(tree)
            os.makedirs(outside)
            with open(os.path.join(outside, "target.zig"), "w") as f:
                f.write('const std = @import("std");\nconst i = std.mem.indexOf(u8, "ab", "b");\n')
            os.symlink(os.path.join(outside, "target.zig"), os.path.join(tree, "link.zig"))
            if hasattr(os, "mkfifo"):
                os.mkfifo(os.path.join(tree, "pipe.zig"))
            r = run_on(tree)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("link.zig: skipped a symbolic link", r.stderr)
        if hasattr(os, "mkfifo"):
            self.assertIn("pipe.zig: skipped, not a regular file", r.stderr)

    def test_a_file_that_is_not_utf8_is_named_and_the_rest_is_checked(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "bad.zig"), "wb") as f:
                f.write(b'const b = "\xff";\n')
            with open(os.path.join(root, "good.zig"), "w") as f:
                f.write('const std = @import("std");\nconst i = std.mem.indexOf(u8, "ab", "b");\n')
            r = run_on(root)
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("bad.zig: not UTF-8 at byte 11", r.stderr)
        self.assertIn("good.zig:2: [deprecated]", r.stdout)

    def test_file_names_cannot_drive_the_terminal(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "x\x1b[31mred\x07.zig"), "w") as f:
                f.write('const std = @import("std");\nconst i = std.mem.indexOf(u8, "ab", "b");\n')
            r = run_on(root)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertNotIn("\x1b", r.stdout)
        self.assertNotIn("\x07", r.stdout)
        self.assertIn("x\\x1b[31mred\\x07.zig:2:", r.stdout)

    def test_one_long_line_takes_linear_time(self):
        # Observed: 40000 `.Debug` tags on one line took about 30 s, because
        # each one scanned the rest of the line for an optimize word. Twice
        # as many take about 1.5 s now and about 2 minutes that way.
        tags = ", ".join([".Debug"] * 80000)
        code, out = scan(f"const a = .{{ {tags} }};\n", timeout=20)
        self.assertEqual(code, 0, out)
        code, out = scan(f"const a = .{{ {tags} }}; // optimize\n", timeout=20)
        self.assertEqual(code, 1, out)
        self.assertIn("80000 deprecated", out)


class IgnoresNonCode(unittest.TestCase):
    def test_comments_and_strings(self):
        source = (
            'const std = @import("std");\n'
            "// std.fmt.allocPrint and std.mem.indexOf in a comment\n"
            'const a = "std.fs.path ** 2 builtin.os";\n'
            "const b =\n"
            "    \\\\std.mem.copyForwards in a multiline string\n"
            ";\n"
            "const c = '*';\n"
        )
        code, out = scan(source)
        self.assertEqual(code, 0, out)

    def test_clean_017_code(self):
        source = (
            'const std = @import("std");\n'
            'const builtin = @import("builtin");\n'
            "const E = enum(u8) { a };\n"
            "fn f(gpa: std.mem.Allocator, d: []u8, s: []const u8) ![]u8 {\n"
            "    @memmove(d[0..s.len], s);\n"
            "    _ = std.mem.findScalar(u8, s, 'a');\n"
            "    _ = std.Io.Dir.path.basename(\"/a/b\");\n"
            "    _ = builtin.target.os.tag;\n"
            "    _ = builtin.optimize.runtimeSafety();\n"
            "    _ = @backingInt(E.a);\n"
            "    _ = @divCeil(@as(u32, 5), 3);\n"
            "    const rule: [4]u8 = @splat('-');\n"
            "    _ = rule;\n"
            '    return gpa.print("{d}", .{1});\n'
            "}\n"
        )
        code, out = scan(source)
        self.assertEqual(code, 0, out)

    def test_skips_build_caches(self):
        with tempfile.TemporaryDirectory() as root:
            for d in (".zig-cache", "zig-out", "zig-pkg"):
                os.makedirs(os.path.join(root, d))
                with open(os.path.join(root, d, "x.zig"), "w") as f:
                    f.write('const std = @import("std");\nconst x = std.fmt.allocPrint;\n')
            r = run_on(root)
            self.assertEqual(r.returncode, 0, r.stdout)


class ReviewHotspots(unittest.TestCase):
    def test_silent_semantic_changes_are_reported_without_failing(self):
        source = (
            'const std = @import("std");\n'
            "const C = struct { const hidden = 1; };\n"
            'const has = @hasDecl(C, "hidden");\n'
            "const n = std.mem.containsAtLeastScalar(u8, \"aa\", 'a', 1);\n"
        )
        code, out = scan(source)
        self.assertEqual(code, 0, out)
        self.assertIn("2 to review", out)
        self.assertNotIn("[review]", out)
        code, out = scan(source, "--review")
        self.assertEqual(code, 0, out)
        self.assertIn("[review] containsAtLeastScalar", out)
        self.assertIn("[review] @hasDecl", out)
        strict_code, _ = scan(source, "--strict")
        self.assertEqual(strict_code, 1)

    def test_evented_io_is_a_review_hotspot(self):
        # std.Io.Evented does not compile on 0.17.0 or 0.17.1; lazy analysis
        # hides that until something calls it.
        source = 'const std = @import("std");\nvar ev: std.Io.Evented = undefined;\nconst ok: std.Io.Threaded = undefined;\n'
        code, out = scan(source, "--review")
        self.assertEqual(code, 0, out)
        self.assertIn("[review] std.Io.Evented -> does not compile on 0.17.0 or 0.17.1", out)
        self.assertNotIn("Threaded ->", out)

    def test_debug_allocator_names_the_entry_point(self):
        code, out = scan('const std = @import("std");\nvar d: std.heap.DebugAllocator(.{}) = .init;\n')
        self.assertEqual(code, 1, out)
        self.assertIn("std.heap.SafeAllocator", out)
        self.assertIn("init.gpa", out)

    def test_void_function_bodies_are_not_void_literals(self):
        source = "fn a() void {}\nfn b() !void {}\nfn c(_: u8) error{X}!void {}\n"
        code, out = scan(source)
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
