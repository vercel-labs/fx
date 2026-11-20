from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import types
import unittest

from scripts.pgso import linux, macos, unit_tests
from scripts.pgso.model import PgsoError
from scripts.pgso.pipeline import (
    FX_CODEGEN_FLAGS,
    PROFILE_PREPARATION_PASSES,
    PipelinePaths,
)


class TransformedUnitTestsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="fx-pgso-unit-tests-")
        self.root = pathlib.Path(self.temporary_directory.name)
        self.paths = PipelinePaths.create(self.root / "run", selector=unit_tests.SELECTOR)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def toolchain(self) -> types.SimpleNamespace:
        return types.SimpleNamespace(
            opt=self.root / "opt",
            llc=self.root / "llc",
            tools=linux.Tools(ld_lld=self.root / "ld.lld", readelf=self.root / "llvm-readelf"),
            platform=linux.ARM64,
            target=linux.ARM64.TARGET,
        )

    def write_executable(self, name: str, body: str) -> pathlib.Path:
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n{body}\n")
        path.chmod(0o755)
        return path

    def test_the_unit_test_artifact_has_its_own_layout(self) -> None:
        self.assertEqual("fx-test", self.paths.control_binary.name)
        self.assertEqual("unit-tests.bc", self.paths.bitcode.name)
        self.assertEqual(("aarch64-linux", "x86_64-linux"), unit_tests.TARGETS)

    def test_every_function_is_marked_minsize_before_the_profile_use_passes(self) -> None:
        argv = unit_tests.optimize_argv(self.toolchain(), self.paths)

        self.assertEqual(
            (
                str(self.root / "opt"),
                "-force-attribute=minsize",
                f"-passes=forceattrs,{PROFILE_PREPARATION_PASSES},default<O2>,mergefunc",
                str(self.paths.bitcode),
                "-o",
                str(self.paths.profile_use_base_bitcode),
            ),
            argv,
        )
        self.assertFalse(any("profile" in item for item in argv[1:3]))

    def test_the_object_uses_the_fx_candidate_code_generation(self) -> None:
        argv = unit_tests.object_argv(self.toolchain(), self.paths)

        self.assertEqual(
            (
                str(self.root / "llc"),
                "-filetype=obj",
                "-O=2",
                *FX_CODEGEN_FLAGS,
                *linux.candidate_object_flags(PipelinePaths.create(self.root / "fx")),
                "-relocation-model=pic",
                str(self.paths.profile_use_bitcode),
                "-o",
                str(self.paths.profile_use_object),
            ),
            argv,
        )

    def test_the_link_reruns_the_recorded_control_link_with_the_transformed_object(self) -> None:
        crt = self.root / "rcrt1.o"
        crt.write_bytes(b"crt")
        record = {
            "argv": ["ld.lld", "-static", "-pie", str(crt), "/cache/test_zcu.o", "-o", "/cache/test"],
            "zig_object": "/cache/test_zcu.o",
            "inputs": {str(crt): linux.sha256_file(crt)},
        }
        (self.paths.logs / "control-link.json").write_text(json.dumps(record), encoding="utf-8")

        argv = unit_tests.link_argv(self.toolchain(), self.paths)

        self.assertEqual(
            [
                str(self.root / "ld.lld"), "-static", "-pie", str(crt), str(self.paths.profile_use_object),
                "-o", str(self.paths.candidate_binary),
            ],
            argv,
        )

    def test_summary_reads_the_runner_last_line(self) -> None:
        self.assertEqual(
            {"passed": 12, "skipped": 0, "failed": 0},
            unit_tests.parse_test_summary("1/12 a...OK\nAll 12 tests passed.\n"),
        )
        self.assertEqual(
            {"passed": 9, "skipped": 2, "failed": 1},
            unit_tests.parse_test_summary("All 3 tests passed.\n9 passed; 2 skipped; 1 failed.\n49 fuzz tests found.\n"),
        )
        with self.assertRaisesRegex(PgsoError, "no summary"):
            unit_tests.parse_test_summary("1/2 a...OK\n2/2 b...thread 1 panic: reached unreachable code\n")

    def test_a_size_pass_that_skips_the_tests_fails_the_step(self) -> None:
        def write(name: str, summary: dict[str, object]) -> None:
            log = {"stdout": json.dumps(summary) + "\n"}
            (self.paths.logs / f"{name}.json").write_text(json.dumps(log), encoding="utf-8")

        write("zero-fill-globals", {"pass": "zero-fill-globals", "zero_filled_globals": 3})
        write("compact-error-names", {"pass": "compact-error-names", "skipped": "no error name table"})

        self.assertEqual(3, unit_tests.require_pass_applied(self.paths, "zero-fill-globals")["zero_filled_globals"])
        with self.assertRaisesRegex(PgsoError, "compact-error-names skipped the unit tests: no error name table"):
            unit_tests.require_pass_applied(self.paths, "compact-error-names")

    def test_a_size_pass_log_that_cannot_be_read_fails_the_step(self) -> None:
        logs = {
            "not-json-stdout": json.dumps({"stdout": "not json"}),
            "not-json-log": "{broken",
            "no-stdout": json.dumps({"stderr": ""}),
            "list-summary": json.dumps({"stdout": "[1, 2]"}),
        }
        for name, text in logs.items():
            (self.paths.logs / f"{name}.json").write_text(text, encoding="utf-8")
        for name in (*logs, "missing"):
            with self.subTest(name), self.assertRaisesRegex(PgsoError, f"^{name} (left no summary|printed a summary)"):
                unit_tests.require_pass_applied(self.paths, name)

    def test_tests_run_from_the_repository_root_with_an_open_stdin(self) -> None:
        repo = self.root / "repo"
        repo.mkdir()
        binary = self.write_executable(
            "fx-test",
            "import os, select, stat, sys\n"
            f"assert os.getcwd() == {str(repo.resolve())!r}\n"
            "assert stat.S_ISFIFO(os.fstat(0).st_mode)\n"
            "assert not select.select([0], [], [], 0)[0], 'stdin is at end of file'\n"
            "sys.stderr.write('1/2 a...OK\\n2/2 b...SKIP\\n1 passed; 1 skipped; 0 failed.\\n')",
        )

        summary = unit_tests.run_tests(binary, repo, self.paths.logs / "unit-tests.json")

        self.assertEqual({"passed": 1, "skipped": 1, "failed": 0, "retried": False}, summary)
        self.assertEqual("passed", json.loads((self.paths.logs / "unit-tests.json").read_text())["status"])

    def test_failed_tests_names_each_failure_and_the_test_that_never_finished(self) -> None:
        output = (
            "1/5 a...OK\n"
            "2/5 b...FAIL (TestExpectedEqual)\n"
            "3/5 c...some output\nFAIL (TestUnexpectedResult)\n"
            "4/5 d...more output\nOK\n"
            "5/5 e...thread 1 panic: attempt to use null value\n"
        )

        self.assertEqual(["b", "c", "e"], unit_tests.failed_tests(output))
        self.assertEqual([], unit_tests.failed_tests("1/1 a...OK\nAll 1 tests passed.\n"))

    def test_a_run_that_passes_only_on_retry_keeps_the_first_failure(self) -> None:
        marker = self.root / "first-run-done"
        binary = self.write_executable(
            "fx-test",
            "import os, pathlib, sys\n"
            f"marker = pathlib.Path({str(marker)!r})\n"
            "if not marker.exists():\n"
            "    marker.touch()\n"
            "    sys.stderr.write('1/2 a...OK\\n2/2 b...thread 1 panic: reached unreachable code\\n')\n"
            "    os.abort()\n"
            "sys.stderr.write('1/2 a...OK\\n2/2 b...OK\\nAll 2 tests passed.\\n')",
        )

        summary = unit_tests.run_tests(binary, self.root, self.paths.logs / "unit-tests.json")

        self.assertEqual(2, summary["passed"])
        self.assertTrue(summary["retried"])
        self.assertEqual(["b"], summary["first_attempt"]["failed_tests"])
        self.assertIn("exit code -6", summary["first_attempt"]["error"])
        first = json.loads((self.paths.logs / "unit-tests.json").read_text())
        retry = json.loads((self.paths.logs / "unit-tests-retry.json").read_text())
        self.assertEqual(("failed", "passed"), (first["status"], retry["status"]))
        self.assertIn("reached unreachable code", first["stderr"])

    def test_the_first_run_log_keeps_every_test_of_a_long_run(self) -> None:
        marker = self.root / "first-run-done"
        binary = self.write_executable(
            "fx-test",
            "import pathlib, sys\n"
            f"marker = pathlib.Path({str(marker)!r})\n"
            "lines = [f'{i}/16000 test number {i} with a long enough name to fill the log...OK' for i in range(1, 16001)]\n"
            "if not marker.exists():\n"
            "    marker.touch()\n"
            "    lines[1] = '2/16000 an early test...FAIL (TestExpectedEqual)'\n"
            "    sys.stderr.write('\\n'.join(lines) + '\\n15999 passed; 0 skipped; 1 failed.\\n')\n"
            "    sys.exit(1)\n"
            "sys.stderr.write('\\n'.join(lines) + '\\nAll 16000 tests passed.\\n')",
        )

        summary = unit_tests.run_tests(binary, self.root, self.paths.logs / "unit-tests.json")

        first = json.loads((self.paths.logs / "unit-tests.json").read_text())
        self.assertGreater(first["stderr_total_chars"], 1024 * 1024)
        self.assertFalse(first["stderr_truncated"])
        self.assertEqual(["an early test"], summary["first_attempt"]["failed_tests"])

    def test_a_failed_or_crashed_test_run_fails_the_step(self) -> None:
        failed = self.write_executable("failed", "import sys\nsys.stderr.write('0 passed; 0 skipped; 1 failed.\\n')")
        with self.assertRaisesRegex(PgsoError, "did not all pass"):
            unit_tests.run_tests(failed, self.root, self.paths.logs / "failed.json")
        crashed = self.write_executable("crashed", "import os\nos.abort()")
        with self.assertRaisesRegex(PgsoError, "failed twice: command failed with exit code -6") as raised:
            unit_tests.run_tests(crashed, self.root, self.paths.logs / "crashed.json")
        self.assertTrue((self.paths.logs / "crashed-retry.json").is_file())
        self.assertIn(f"logs: {self.paths.logs / 'crashed.json'} and {self.paths.logs / 'crashed-retry.json'}", str(raised.exception))

    def test_the_step_refuses_a_target_that_is_not_linux(self) -> None:
        toolchain = types.SimpleNamespace(target="aarch64-macos", platform=macos)
        with self.assertRaisesRegex(PgsoError, "only on Linux"):
            unit_tests.transformed_unit_tests(toolchain, self.root, self.root / "output")
        self.assertFalse((self.root / "output").exists())


if __name__ == "__main__":
    unittest.main()
