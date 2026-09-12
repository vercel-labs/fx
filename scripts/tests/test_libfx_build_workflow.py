from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/build-libfx.yml"


class LibfxBuildIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        validation = workflow.split("      - name: Validate build identity\n", 1)[1]
        cls.script = textwrap.dedent(
            validation.split("        run: |\n", 1)[1].split("\n  native:\n", 1)[0]
        )
        cls.sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True
        ).strip()
        cls.git_dir = subprocess.check_output(
            ["git", "rev-parse", "--absolute-git-dir"], cwd=REPO_ROOT, text=True
        ).strip()

    def validate(
        self,
        version: str,
        channel: str,
        *,
        source_sha: str | None = None,
        source_version: str = "0.9.3",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="libfx-build-identity-") as tmp:
            root = pathlib.Path(tmp)
            (root / "src").mkdir()
            (root / "src/main.zig").write_text(
                f'pub const version = "{source_version}";\n', encoding="utf-8"
            )
            return subprocess.run(
                ["bash", "-euo", "pipefail", "-c", self.script],
                cwd=root,
                env=dict(
                    os.environ,
                    GIT_DIR=self.git_dir,
                    SOURCE_SHA=self.sha if source_sha is None else source_sha,
                    LIBFX_VERSION=version,
                    UPDATE_CHANNEL=channel,
                ),
                capture_output=True,
                text=True,
            )

    def test_accepts_stable_and_existing_dev_format(self) -> None:
        for version, channel in (
            ("0.9.3", "stable"),
            (f"0.9.3-dev.1.g{self.sha[:12]}", "dev"),
            (f"0.9.3-dev.123456.g{self.sha[:12]}", "dev"),
        ):
            with self.subTest(version=version, channel=channel):
                result = self.validate(version, channel)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_rejects_noncanonical_or_different_source_sha(self) -> None:
        for sha in ("", "main", self.sha[:12], "0" * 40, self.sha + "\n"):
            with self.subTest(sha=sha):
                result = self.validate("0.9.3", "stable", source_sha=sha)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("source_sha", result.stdout)

    def test_rejects_source_versions_that_are_not_stable_semver(self) -> None:
        for version in ("", "01.9.3", "0.09.3", "0.9.03", "0.9.3-beta", "0.9.3+build"):
            with self.subTest(version=version):
                result = self.validate(version, "stable", source_version=version)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("src/main.zig version", result.stdout)

    def test_rejects_wrong_version_or_channel(self) -> None:
        dev = f"0.9.3-dev.1.g{self.sha[:12]}"
        for version, channel in (
            ("0.9.4", "stable"), ("v0.9.3", "stable"), (dev, "stable"),
            ("0.9.3", "dev"), (dev.replace("0.9.3", "0.9.4"), "dev"),
            (dev.replace(".1.", ".0."), "dev"),
            (dev.replace(".1.", ".01."), "dev"),
            (dev.replace(self.sha[:12], "0" * 12), "dev"),
            (dev + "+build", "dev"), (dev + "\n", "dev"),
            ("0.9.3", ""), ("0.9.3", "latest"), ("0.9.3", "stable\n"),
        ):
            with self.subTest(version=version, channel=channel):
                result = self.validate(version, channel)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("::error::", result.stdout)


if __name__ == "__main__":
    unittest.main()
