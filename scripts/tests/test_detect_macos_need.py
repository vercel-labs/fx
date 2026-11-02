from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "detect-macos-need.sh"
PLATFORM_LIST = "tests/e2e/macos-platform-tests.json"


class DetectMacosNeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": self.temp.name,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        self.git("init", "-q")
        self.write(PLATFORM_LIST, '["listed.test.ts"]\n')
        self.write("src/plain.zig", "pub fn plain() void {}\n")
        self.write("src/mac.zig", "if (builtin.os.tag == .macos) {}\n")
        self.write("README.md", "fx\n")
        self.base = self.commit("base")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, check=True,
            capture_output=True, text=True,
        )
        return result.stdout.strip()

    def write(self, path: str, content: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def detect(
        self, base: str | None = None, head: str = "HEAD", **env: str,
    ) -> tuple[int, dict[str, str], str]:
        output_path = self.root.parent / f"{self.root.name}-output"
        output_path.write_text("", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), base or self.base, head],
            cwd=self.root,
            env={**self.env, "GITHUB_OUTPUT": str(output_path), **env},
            capture_output=True,
            text=True,
        )
        outputs = dict(
            line.split("=", 1)
            for line in output_path.read_text(encoding="utf-8").splitlines()
        )
        output_path.unlink()
        return result.returncode, outputs, result.stdout + result.stderr

    def assert_needed(self, *, sdk_native: bool = False, **env: str) -> str:
        code, outputs, text = self.detect(**env)
        self.assertEqual(0, code, text)
        self.assertEqual("true", outputs.get("needed"), text)
        self.assertEqual("true" if sdk_native else "false", outputs.get("sdk_native"), text)
        return text

    def assert_not_needed(self) -> None:
        code, outputs, text = self.detect()
        self.assertEqual(0, code, text)
        self.assertEqual({"needed": "false", "sdk_native": "false"}, outputs, text)

    def test_change_without_platform_behavior_skips_macos(self) -> None:
        self.write("README.md", "fx docs\n")
        self.write("src/plain.zig", "pub fn plain() u8 { return 1; }\n")
        self.write("src/windows.zig", "if (builtin.os.tag == .windows) {} else {}\n")
        self.write("src/linux_target.zig", "const name = .linux_x64;\n")
        self.write("tests/e2e/unlisted.test.ts", "test\n")
        self.commit("head")

        self.assert_not_needed()

    def test_zig_file_with_macos_code_needs_macos(self) -> None:
        self.write("src/mac.zig", "if (builtin.os.tag == .macos) { run(); }\n")
        self.commit("head")

        self.assertIn("src/mac.zig", self.assert_needed())

    def test_linux_branch_needs_macos_because_macos_takes_the_else_path(self) -> None:
        self.write("src/self_exe.zig", "if (comptime builtin.os.tag == .linux) {} else {}\n")
        self.commit("head")

        self.assertIn("src/self_exe.zig", self.assert_needed())

    def test_linux_namespace_and_bsd_checks_need_macos(self) -> None:
        self.write("src/syscall.zig", "const pid = std.os.linux.getpid();\n")
        self.write("src/bsd.zig", "if (builtin.os.tag.isBSD()) {}\n")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/syscall.zig", text)
        self.assertIn("src/bsd.zig", text)

    def test_removing_macos_code_needs_macos(self) -> None:
        self.write("src/mac.zig", "pub fn now_plain() void {}\n")
        self.commit("head")

        self.assertIn("src/mac.zig", self.assert_needed())

    def test_deleted_and_renamed_macos_files_need_macos(self) -> None:
        self.git("mv", "src/mac.zig", "src/renamed.zig")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/mac.zig", text)
        self.assertIn("src/renamed.zig", text)

    def test_build_and_signing_changes_need_macos(self) -> None:
        for path in ("build.zig", "build.zig.zon", "scripts/sign-and-notarize-macos.sh"):
            with self.subTest(path=path):
                self.write(path, f"{path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

    def test_native_sdk_changes_also_check_the_addon(self) -> None:
        for path in ("src/napi_core_main.zig", "sdk/node.js", "sdk/tests/test-node-napi.mjs"):
            with self.subTest(path=path):
                self.write(path, f"// {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed(sdk_native=True))
                self.base = self.git("rev-parse", "HEAD")

    def test_macos_check_inputs_need_macos(self) -> None:
        self.write(".github/workflows/macos.yml", "name: macOS\n")
        self.commit("workflow")
        self.assert_needed(sdk_native=True)
        self.base = self.git("rev-parse", "HEAD")

        for path in (
            "scripts/detect-macos-need.sh",
            "scripts/smoke-binary.sh",
            "tests/e2e/ci-run-files.sh",
            "tests/e2e/ci-shards.ts",
        ):
            with self.subTest(path=path):
                self.write(path, f"# {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

    def test_listed_platform_test_needs_macos_and_nested_paths_do_not(self) -> None:
        self.write("tests/e2e/listed.test.ts", "test\n")
        self.commit("listed")
        self.assertIn("listed.test.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/fixtures/listed.test.ts", "fixture\n")
        self.commit("nested")
        self.assert_not_needed()

    def test_shared_e2e_helper_with_platform_branch_needs_macos(self) -> None:
        self.write("tests/e2e/helper.ts", 'const mac = process.platform === "darwin";\n')
        self.commit("helper")
        self.assertIn("tests/e2e/helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/helper.ts", "const mac = false;\n")
        self.commit("remove branch")
        self.assertIn("tests/e2e/helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/os-helper.ts", 'const linux = platform() === "linux";\n')
        self.commit("node:os helper")
        self.assertIn("tests/e2e/os-helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/plain.ts", "export const value = 1;\n")
        self.commit("plain helper")
        self.assert_not_needed()

    def test_requests_force_the_checks(self) -> None:
        self.assertIn("ci:macos label", self.assert_needed(MACOS_REQUESTED="ci:macos label"))
        self.assert_needed(sdk_native=True, SDK_NATIVE_REQUESTED="true")

    def test_unreadable_revision_fails_instead_of_skipping(self) -> None:
        code, outputs, text = self.detect(base="does-not-exist")

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("cannot read revision", text)

    def test_missing_platform_list_fails_instead_of_skipping(self) -> None:
        (self.root / PLATFORM_LIST).unlink()

        code, outputs, text = self.detect()

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("not a JSON array", text)


if __name__ == "__main__":
    unittest.main()
