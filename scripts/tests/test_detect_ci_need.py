from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "detect-ci-need.sh"


class DetectCiNeedTests(unittest.TestCase):
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
        self.write("src/acp/server.zig", "pub fn serve() void {}\n")
        self.write("src/mcp/engine.zig", "pub fn run() void {}\n")
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

    def assert_needs(self, *, libfx: bool, mcp: bool, **env: str) -> str:
        code, outputs, text = self.detect(**env)
        self.assertEqual(0, code, text)
        self.assertEqual(
            {"libfx": str(libfx).lower(), "mcp": str(mcp).lower()}, outputs, text,
        )
        return text

    def commit_each(self, paths: tuple[str, ...], *, libfx: bool, mcp: bool) -> None:
        for path in paths:
            with self.subTest(path=path):
                self.write(path, f"// {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needs(libfx=libfx, mcp=mcp))
                self.base = self.git("rev-parse", "HEAD")

    def test_change_outside_both_checks_skips_them(self) -> None:
        self.write("README.md", "fx docs\n")
        self.write("src/ui/composer.zig", "pub fn draw() void {}\n")
        self.write("src/core/agent/loop.zig", "pub fn run() void {}\n")
        self.write("src/wasm_term_main.zig", "pub fn main() void {}\n")
        self.write("tests/e2e/composer.test.ts", "test\n")
        self.write("tests/e2e/fixtures/fake-gateway.ts", "export {};\n")
        self.write(".github/workflows/macos.yml", "name: macOS\n")
        self.commit("head")

        self.assert_needs(libfx=False, mcp=False)

    def test_libfx_paths_need_only_the_libfx_check(self) -> None:
        self.commit_each((
            "sdk/durable.js",
            "sdk/tests/test-durable.mjs",
            "tests/tla/sdk/DurableSession.tla",
            "tests/tla/drivers/drive.mjs",
            "tests/tla/drivers/session-process.mjs",
            "src/napi_core_main.zig",
            "src/napi_fetch_state.zig",
            "src/wasm_core_main.zig",
            "src/acp/libfx_steering.zig",
            "src/core/hosts/host.zig",
            "src/core/session_manager/api.zig",
        ), libfx=True, mcp=False)

    def test_mcp_paths_need_only_the_mcp_check(self) -> None:
        self.commit_each((
            "src/mcp/engine.zig",
            "src/core/mcp_host/host.zig",
            "src/core/mcp/config.zig",
            "tests/tla/mcp/Engine.tla",
            "tests/tla/mcp_host/Host.tla",
            "tests/tla/drivers/mcp/driver.ts",
            "tests/tla/drivers/mcp_host/sign-in.test.ts",
            "tests/tla/drivers/lib/context.ts",
            "tests/e2e/fixtures/mcp-legacy-stdio.mjs",
            "tests/e2e/tmux-helpers.ts",
            "tests/evals/eval-helpers.ts",
            "tests/e2e/render-lab/tape.ts",
        ), libfx=False, mcp=True)

    def test_build_and_check_inputs_need_both_checks(self) -> None:
        self.commit_each((
            "build.zig",
            "build.zig.zon",
            ".github/workflows/ci.yml",
            "scripts/detect-ci-need.sh",
        ), libfx=True, mcp=True)

    def test_mcp_driver_folders_do_not_need_the_libfx_check(self) -> None:
        self.write("tests/tla/drivers/mcp/scenarios/u01-wire.mjs", "export {};\n")
        self.commit("nested driver")

        self.assert_needs(libfx=False, mcp=True)

    def test_deleted_and_renamed_files_need_their_checks(self) -> None:
        self.git("mv", "src/acp/server.zig", "src/server.zig")
        self.git("rm", "-q", "src/mcp/engine.zig")
        self.commit("head")

        text = self.assert_needs(libfx=True, mcp=True)
        self.assertIn("src/acp/server.zig", text)
        self.assertIn("src/mcp/engine.zig", text)

    def test_request_forces_both_checks(self) -> None:
        text = self.assert_needs(libfx=True, mcp=True, CI_NEED_REQUESTED="push to main")
        self.assertIn("push to main", text)

    def test_unreadable_revision_fails_instead_of_skipping(self) -> None:
        code, outputs, text = self.detect(base="does-not-exist")

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("cannot read revision", text)


if __name__ == "__main__":
    unittest.main()
