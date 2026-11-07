"""Package contract: frontmatter, links, bundled files, and 0.17.x facts.

Run from the skill folder: python3 -m unittest discover -s scripts
"""
import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def description(skill):
    m = re.match(r"---\nname: (.+)\ndescription: >-\n((?:  .+\n)+)---\n", skill)
    return m, (" ".join(line.strip() for line in m.group(2).splitlines()) if m else "")


def zig_017():
    try:
        version = subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        return None
    return version if version.startswith("0.17.") else None


class Package(unittest.TestCase):
    def setUp(self):
        self.skill = read("SKILL.md")

    def test_frontmatter(self):
        m, text = description(self.skill)
        self.assertIsNotNone(m, "SKILL.md needs name and folded description frontmatter")
        self.assertEqual(m.group(1).strip(), "zig")
        self.assertIn("0.17", text)
        self.assertLessEqual(len(text), 1024)

    def test_description_names_deprecated_calls(self):
        # Observed: a prompt about replacing std.mem.copyForwards in a 0.17
        # project did not load the skill when the description named only topics.
        _, text = description(self.skill)
        for name in ("allocPrint", "indexOf", "copyForwards", "std.fs", "@intFromEnum"):
            self.assertIn(name, text)

    def test_description_covers_practice_and_versions(self):
        # The skill replaces zig-best-practices, which loaded for any .zig edit.
        _, text = description(self.skill)
        for needle in (".zig", "ownership", "allocator", "concurrency", "fuzz", "binary size", "0.17.1", "merg", "install", "0.16 branch"):
            self.assertIn(needle, text)

    def test_is_self_contained(self):
        # The two skills it replaces sent the agent to each other. After the
        # merge, a pointer to either one is a dead route.
        for path in self.all_text_files():
            text = read(path)
            for old in ("zig-best-practices", "`zig-0.17` skill", "$zig-0.17"):
                self.assertNotIn(old, text, f"{path} still routes to {old}")

    def test_no_reference_recommends_debug_allocator(self):
        # Observed: the old practice reference named std.heap.DebugAllocator for
        # leak-sensitive tests, which Zig 0.17 deprecates. Every mention must say so.
        # Scripts and evals name it as test data; prose must not recommend it.
        for path in self.all_text_files():
            if not path.endswith(".md"):
                continue
            text = read(path)
            if path == "SKILL.md":
                # The description lists DebugAllocator among names to replace.
                text = text.split("---", 2)[2]
            for paragraph in re.split(r"\n\s*\n", text):
                if "DebugAllocator" in paragraph:
                    self.assertRegex(paragraph, r"(?i)deprecat|SafeAllocator", f"{path}: {paragraph.strip()[:200]}")

    def test_entry_point_recipe(self):
        # Observed: without it, an agent read std 23 times and spent 1.48M input
        # tokens to hand-build an allocator switch and a second std.Io.Threaded.
        self.assertIn("std.process.Init", self.skill)
        self.assertIn("init.gpa", self.skill)
        self.assertIn("init.io", self.skill)
        self.assertIn("fn mainExample(init: std.process.Init)", read("references", "examples.zig"))

    def test_patch_release_status(self):
        # Observed: an agent asked about 0.17.1 reported every 0.17.0 regression
        # as still open, because the skill only knew 0.17.0.
        toolchain = read("references", "toolchain.md")
        section = toolchain[toolchain.index("## Zig 0.17.1"):]
        for needle in ("#37006", "#36986", "#36444", "#37050", "#37228", "#37310", "#37357", "std.Io.Evented", "http.Reader", "resize_fail_index", "payload_pending", "closing = true", "--verbose-llvm-bc", "0x0B17C0DE"):
            self.assertIn(needle, section)
        self.assertIn("references/toolchain.md", self.skill)
        self.assertIn("0.17.1", self.skill)

    def test_silent_017_1_behavior_changes_reach_the_core(self):
        # Observed in a real 0.17.0 to 0.17.1 upgrade: both passed a clean build.
        # The HTTP drain hung MCP requests; the optimized bitcode broke PGO input.
        self.assertIn("std.http", self.skill)
        self.assertIn("-femit-llvm-bc", self.skill)

    def test_termios_warning_survives(self):
        # #37228 closed in 0.17.1 but std.c.termios is still the kernel layout.
        toolchain = read("references", "toolchain.md")
        self.assertRegex(toolchain, r"(?s)termios.{0,400}(still|not fixed)")

    def test_examples_compile_on_017(self):
        self.assertIn("references/examples.zig", self.skill)
        version = zig_017()
        if version is None:
            self.skipTest("no Zig 0.17.x on PATH")
        with tempfile.TemporaryDirectory() as cache:
            r = subprocess.run(
                ["zig", "test", os.path.join(ROOT, "references", "examples.zig"), "--cache-dir", cache, "--global-cache-dir", cache],
                capture_output=True, text=True,
            )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_linked_files_exist(self):
        links = re.findall(r"\]\(((?:references|scripts|evals)/[^)#]+)\)", self.skill)
        self.assertTrue(links, "SKILL.md should link its references")
        for link in links:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, link)), link)

    def test_every_reference_is_linked(self):
        for name in os.listdir(os.path.join(ROOT, "references")):
            self.assertIn(f"references/{name}", self.skill, f"{name} is never loaded")

    def test_core_stays_lean(self):
        self.assertLess(len(self.skill.splitlines()), 240)

    def test_evals_parse(self):
        evals = json.loads(read("evals", "evals.json"))
        self.assertEqual(evals["skill"], "zig")
        self.assertGreaterEqual(len(evals["cases"]), 8)
        ids = {case["id"] for case in evals["cases"]}
        self.assertLessEqual({"merge-ported-main", "toolchain-side-by-side", "entry-point-allocator", "patch-release-status", "migrate-silent-changes"}, ids)
        for case in evals["cases"]:
            self.assertTrue(case["id"] and case["prompt"] and case["assertions"])
            self.assertNotIn("$zig-0.17", case["prompt"])

    def test_bundles_migrate_with_tests(self):
        # Observed: agents porting a 0.16 branch wrote their own rename script.
        for name in ("migrate.py", "test_migrate.py", "check_deprecated.py", "test_check_deprecated.py"):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, "scripts", name)), name)
        self.assertIn("scripts/migrate.py", self.skill)

    def test_checks_the_compiler_first(self):
        # Observed: an agent verified a 0.17 project with Homebrew's 0.16 and
        # reported it unverified. 0.16 does not enforce minimum_zig_version; it
        # fails with errors that look like bugs in correct 0.17 code.
        self.assertIn("which -a zig", self.skill)
        self.assertIn("no field or member function named 'print'", self.skill)
        self.assertIn("no field named 'debug' in enum", self.skill)

    def test_toolchain_install_is_side_by_side_and_verified(self):
        toolchain = read("references", "toolchain.md")
        for needle in ("ziglang.org/download/index.json", "shasum -a 256", "zig-aarch64-macos-0.17.1.tar.xz"):
            self.assertIn(needle, toolchain)
        self.assertNotRegex(toolchain, r"(?m)^\s*brew (upgrade|link|unlink) zig")

    def test_eisconn_gotcha_names_its_trigger(self):
        toolchain = read("references", "toolchain.md")
        gotcha = toolchain[toolchain.index("EISCONN") - 400:toolchain.index("EISCONN") + 600]
        self.assertIn("Select.cancel", gotcha)

    def test_no_personal_paths(self):
        # The fx repository's public-surface check rejects these.
        for path in self.all_text_files():
            # Built from parts so this file doesn't trip that check itself.
            for m in re.finditer("/" + "Users" + r"/([^/\s]+)/", read(path)):
                self.assertIn(m.group(1), ("example", "tester", "private", "me", "<you>"), path)

    def all_text_files(self):
        out = []
        for root, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for name in files:
                if name.endswith((".md", ".py", ".json", ".yaml", ".zig")) and name != "test_package.py":
                    out.append(os.path.relpath(os.path.join(root, name), ROOT))
        return out


if __name__ == "__main__":
    unittest.main()
