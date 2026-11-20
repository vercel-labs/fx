from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

from scripts.pgso.pipeline import unoptimized_bitcode_argv


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]


class PgsoBuildStepTests(unittest.TestCase):
    def assert_emits_bitcode(self, selector: str, output_name: str) -> None:
        """`pgso-ir`'s compile, run again the way `emit_bitcode` runs it,
        writes the module Zig generated: LLVM's own writer wraps Darwin
        bitcode, and Zig's never does."""
        with tempfile.TemporaryDirectory(prefix="fx-pgso-build-step-") as tmp:
            result = subprocess.run(
                [
                    "zig",
                    "build",
                    "pgso-ir",
                    f"-Dpgso-artifact={selector}",
                    "-Doptimize=ReleaseSafe",
                    "-Dtarget=aarch64-macos",
                    "--prefix",
                    tmp,
                    "--verbose",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            bitcode = pathlib.Path(tmp) / output_name
            rerun = subprocess.run(
                unoptimized_bitcode_argv(result.stdout + "\n" + result.stderr, bitcode),
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, rerun.returncode, rerun.stdout + rerun.stderr)
            self.assertGreater(bitcode.stat().st_size, 0)
            with bitcode.open("rb") as stream:
                self.assertEqual(b"BC\xc0\xde", stream.read(4))

    def test_ir_step_requires_artifact_selection(self) -> None:
        result = subprocess.run(
            ["zig", "build", "pgso-ir"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "pgso-ir requires -Dpgso-artifact",
            result.stdout + result.stderr,
        )

    def test_fx_ir_step_emits_release_safe_bitcode(self) -> None:
        self.assert_emits_bitcode("fx", "fx.bc")

    def test_benchmark_ir_step_emits_release_safe_bitcode(self) -> None:
        cases = {
            "file_index": "file-index.bc",
            "ui_activity": "ui-activity.bc",
            "approval_review": "approval-review.bc",
        }
        for selector, output_name in cases.items():
            with self.subTest(selector=selector):
                self.assert_emits_bitcode(selector, output_name)


if __name__ == "__main__":
    unittest.main()
