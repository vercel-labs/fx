"""Tests for migrate.py. Run: python3 -m unittest discover -s scripts"""
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import migrate  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "migrate.py")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def run(text):
    out, _counts, notes = migrate.migrate("t.zig", text)
    return out, notes


class Renames(unittest.TestCase):
    def check(self, before, after):
        self.assertEqual(run(before)[0], after)

    def test_mem_find_family(self):
        self.check("_ = std.mem.indexOf(u8, a, b);", "_ = std.mem.find(u8, a, b);")
        self.check("_ = std.mem.indexOfScalarPos(u8, a, 1, 'x');", "_ = std.mem.findScalarPos(u8, a, 1, 'x');")
        self.check("_ = std.mem.lastIndexOfScalar(u8, a, '.');", "_ = std.mem.findScalarLast(u8, a, '.');")

    def test_mem_alias(self):
        self.check("const mem = std.mem;\n_ = mem.indexOfAny(u8, a, \" \");\n",
                   "const mem = std.mem;\n_ = mem.findAny(u8, a, \" \");\n")

    def test_containers_and_namespaces(self):
        self.check("var l: std.ArrayListUnmanaged(u8) = .empty;", "var l: std.ArrayList(u8) = .empty;")
        self.check("const T = std.builtin.Type;", "const T = std.lang.Type;")
        self.check("const m: std.builtin.OptimizeMode = .debug;", "const m: std.lang.Optimize = .debug;")
        self.check("const m: std.lang.OptimizeMode = .debug;", "const m: std.lang.Optimize = .debug;")
        self.check("_ = std.fs.path.join;", "_ = std.Io.Dir.path.join;")
        self.check("_ = try std.fs.path.resolve(gpa, &.{p});", "_ = try std.Io.Dir.path.resolveAlloc(gpa, &.{p});")

    def test_names_after_a_range(self):
        self.check("_ = s[0..std.mem.lastIndexOfScalar(u8, s, '/').?];", "_ = s[0..std.mem.findScalarLast(u8, s, '/').?];")

    def test_optimize_tags_in_build_options(self):
        self.check("_ = b.addExecutable(.{ .optimize = .ReleaseSmall });", "_ = b.addExecutable(.{ .optimize = .small });")
        self.check("const strip = optimize != .Debug;", "const strip = optimize != .debug;")
        self.check("_ = options.optimize == .ReleaseFast;", "_ = options.optimize == .ReleaseFast;")

    def test_ascii_find_ignore_case(self):
        self.check("_ = std.ascii.indexOfIgnoreCase(h, n);", "_ = std.ascii.findIgnoreCase(h, n);")
        self.check("_ = std.ascii.indexOfIgnoreCasePosLinear(h, 0, n);", "_ = std.ascii.findIgnoreCasePosLinear(h, 0, n);")
        self.check("const ascii = std.ascii;\n_ = ascii.indexOfIgnoreCasePos(h, 0, n);\n",
                   "const ascii = std.ascii;\n_ = ascii.findIgnoreCasePos(h, 0, n);\n")

    def test_buf_print(self):
        self.check("_ = try std.fmt.bufPrint(&buf, \"{d}\", .{n});", "_ = try std.mem.print(&buf, \"{d}\", .{n});")

    def test_alloc_print_receivers(self):
        self.check("_ = try std.fmt.allocPrint(gpa, \"{d}\", .{n});", "_ = try gpa.print(\"{d}\", .{n});")
        self.check("_ = try std.fmt.allocPrint(self.arena.allocator(), \"x\", .{});", "_ = try self.arena.allocator().print(\"x\", .{});")
        self.check("_ = try std.fmt.allocPrint(if (a) g else h, \"x\", .{});", "_ = try (if (a) g else h).print(\"x\", .{});")
        self.check("_ = try std.fmt.allocPrintSentinel(gpa, \"x\", .{}, 0);", "_ = try gpa.printSentinel(\"x\", .{}, 0);")

    def test_fmt_alias_is_dropped_once_unused(self):
        self.check("const fmt = std.fmt;\nfn f() !void {\n    _ = try fmt.allocPrint(gpa, \"x\", .{});\n}\n",
                   "fn f() !void {\n    _ = try gpa.print(\"x\", .{});\n}\n")

    def test_builtin_target_fields(self):
        self.check("const builtin = @import(\"builtin\");\nconst t = builtin.os.tag;\n",
                   "const builtin = @import(\"builtin\");\nconst t = builtin.target.os.tag;\n")
        self.check("const a = @import(\"builtin\").cpu.arch;", "const a = @import(\"builtin\").target.cpu.arch;")

    def test_build_mode_comparisons(self):
        self.check("const builtin = @import(\"builtin\");\nconst d = builtin.mode == .Debug;\n",
                   "const builtin = @import(\"builtin\");\nconst d = builtin.optimize == .debug;\n")
        self.check("const s = @import(\"builtin\").mode != .ReleaseSafe;", "const s = @import(\"builtin\").optimize != .safe;")


class Boundaries(unittest.TestCase):
    def test_strings_and_comments_are_untouched(self):
        text = ("// std.mem.indexOf in a comment\n"
                "const a = \"std.fmt.bufPrint\";\n"
                "const b =\n    \\\\std.ArrayListUnmanaged\n;\n")
        self.assertEqual(run(text)[0], text)

    def test_other_receivers_are_untouched(self):
        for text in ("_ = self.mem.indexOf(x);", "_ = my.std.mem.indexOf(x);", "_ = builtin.target.os.tag;", "_ = cfg.mode == .Debug;"):
            self.assertEqual(run(text)[0], text)

    def test_judgment_sites_are_reported_not_rewritten(self):
        text = "_ = try std.fmt.allocPrint(\n    // pick one\n    gpa,\n    \"x\",\n    .{},\n);\n"
        out, notes = run(text)
        self.assertEqual(out, text)
        self.assertTrue(notes)
        text = "const builtin = @import(\"builtin\");\nconst s = switch (builtin.mode) {\n    .Debug => 1,\n    else => 2,\n};\n"
        out, notes = run(text)
        self.assertEqual(out, text)
        self.assertTrue(any("mode" in n for n in notes))

    def test_idempotent(self):
        text = ("const std = @import(\"std\");\nconst builtin = @import(\"builtin\");\nconst fmt = std.fmt;\n"
                "fn f(gpa: std.mem.Allocator, buf: []u8) !void {\n"
                "    _ = std.mem.indexOf(u8, buf, \"a\");\n    _ = try fmt.allocPrint(gpa, \"{s}\", .{buf});\n"
                "    _ = try std.fmt.bufPrint(buf, \"x\", .{});\n    _ = builtin.mode == .ReleaseFast;\n}\n")
        once = run(text)[0]
        self.assertNotEqual(once, text)
        self.assertEqual(run(once)[0], once)


class Cli(unittest.TestCase):
    def test_walks_directories_and_writes_only_with_flag(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "src"))
            os.makedirs(os.path.join(d, ".zig-cache"))
            src = os.path.join(d, "src", "a.zig")
            cached = os.path.join(d, ".zig-cache", "b.zig")
            for p in (src, cached):
                with open(p, "w") as f:
                    f.write("_ = std.mem.indexOf(u8, a, b);\n")
            dry = subprocess.run([sys.executable, SCRIPT, d], capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("files changed: 1", dry.stdout)
            self.assertIn("indexOf", read(src))
            subprocess.run([sys.executable, SCRIPT, "--write", d], check=True, capture_output=True)
            self.assertIn("std.mem.find(", read(src))
            self.assertIn("indexOf", read(cached))


class Compiles(unittest.TestCase):
    def test_migrated_code_compiles_on_017(self):
        try:
            version = subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip()
        except FileNotFoundError:
            self.skipTest("zig is not on PATH")
        if not version.startswith("0.17."):
            self.skipTest(f"zig {version} is not 0.17")
        text = ("const std = @import(\"std\");\nconst builtin = @import(\"builtin\");\nconst mem = std.mem;\nconst fmt = std.fmt;\n"
                "test {\n    const gpa = std.testing.allocator;\n"
                "    const s = try fmt.allocPrint(gpa, \"{d}-{s}\", .{ 7, \"x\" });\n    defer gpa.free(s);\n"
                "    try std.testing.expectEqual(@as(?usize, 1), mem.indexOfScalar(u8, s, '-'));\n"
                "    try std.testing.expectEqual(@as(?usize, 2), std.mem.lastIndexOf(u8, s, \"x\"));\n"
                "    try std.testing.expectEqual(@as(?usize, 0), std.ascii.indexOfIgnoreCase(\"Ab\", \"a\"));\n"
                "    var buf: [8]u8 = undefined;\n    try std.testing.expectEqualStrings(\"ok\", try std.fmt.bufPrint(&buf, \"ok\", .{}));\n"
                "    var l: std.ArrayListUnmanaged(u8) = .empty;\n    defer l.deinit(gpa);\n    try l.append(gpa, 1);\n"
                "    try std.testing.expect(builtin.os.tag == builtin.os.tag);\n"
                "    _ = builtin.mode == .Debug;\n    const m: std.builtin.OptimizeMode = .debug;\n    _ = m;\n}\n")
        out, _ = run(text)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "m.zig")
            with open(p, "w") as f:
                f.write(out)
            r = subprocess.run(["zig", "test", p, "--cache-dir", d, "--global-cache-dir", d], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, out + r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
