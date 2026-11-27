#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PATH = pathlib.Path(__file__).with_name("check_budgets.py")
SPEC = importlib.util.spec_from_file_location("check_budgets", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
check_budgets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_budgets)

SESSIONS = "fx sessions --json"
HELP = "fx help"
BASELINE = "process baseline"
RUN_TIMES_PER_ROUND = 20


def write_side(rounds_dir, side, command, round_means_ms):
    side_dir = rounds_dir / side
    side_dir.mkdir(parents=True, exist_ok=True)
    for index, mean_ms in enumerate(round_means_ms):
        mean_s = mean_ms / 1000.0
        result = {
            "command": command,
            "mean": mean_s,
            "median": mean_s,
            "min": mean_s,
            "max": mean_s,
            "stddev": 0.0,
            "times": [mean_s] * RUN_TIMES_PER_ROUND,
        }
        name = command.replace(" ", "_").replace("/", "_")
        (side_dir / f"{name}.{index}.json").write_text(json.dumps({"results": [result]}))


class BudgetComparisonTests(unittest.TestCase):
    def run_checker(self, pr, base=None, raw_pr_files=None):
        with tempfile.TemporaryDirectory() as tmp:
            rounds_dir = pathlib.Path(tmp) / "rounds"
            for command, round_means_ms in pr.items():
                write_side(rounds_dir, "pr", command, round_means_ms)
            for command, round_means_ms in (base or {}).items():
                write_side(rounds_dir, "base", command, round_means_ms)
            for name, text in (raw_pr_files or {}).items():
                side_dir = rounds_dir / "pr"
                side_dir.mkdir(parents=True, exist_ok=True)
                (side_dir / name).write_text(text)
            env = os.environ.copy()
            env["FX_BENCH_ROUNDS_DIR"] = str(rounds_dir)
            return subprocess.run(
                [sys.executable, str(MODULE_PATH)],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_identical_pair_passes(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.0] * 5},
            base={SESSIONS: [2.0] * 5},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("PASS  fx sessions --json", result.stdout)

    def test_ten_percent_slower_passes(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.2] * 5},
            base={SESSIONS: [2.0] * 5},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("PASS  fx sessions --json", result.stdout)

    def test_twenty_percent_slower_fails(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.4] * 5},
            base={SESSIONS: [2.0] * 5},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("FAIL  fx sessions --json", result.stdout)

    def test_slow_host_slows_both_sides_and_passes(self) -> None:
        # Both sides run on the same slow host, so both are 50% above a normal run.
        result = self.run_checker(
            pr={SESSIONS: [1.8] * 5, BASELINE: [0.9] * 5},
            base={SESSIONS: [1.8] * 5, BASELINE: [0.9] * 5},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("PASS  fx sessions --json", result.stdout)

    def test_raw_guard_fails_even_when_margin_holds(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [3.2] * 5},
            base={SESSIONS: [3.2] * 5},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("FAIL  fx sessions --json", result.stdout)
        self.assertIn("raw guard", result.stdout)

    def test_missing_base_result_fails_closed(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.0] * 5},
            base={},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("no base result for fx sessions --json", result.stdout)

    def test_zero_base_mean_fails_with_named_cause(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.0] * 5},
            base={SESSIONS: [0.0] * 5},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("base mean is not positive", result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_command_missing_from_pr_fails(self) -> None:
        # A renamed or dropped benchmark must not pass by having no PR result.
        result = self.run_checker(
            pr={HELP: [2.0] * 5},
            base={SESSIONS: [2.0] * 5, HELP: [2.0] * 5},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("no PR result for fx sessions --json", result.stdout)

    def test_malformed_round_file_fails_with_named_cause(self) -> None:
        for label, text in (
            ("invalid JSON", "{not json"),
            ("wrong shape", json.dumps({"results": []})),
        ):
            with self.subTest(label=label):
                result = self.run_checker(
                    pr={SESSIONS: [2.0] * 5},
                    base={SESSIONS: [2.0] * 5},
                    raw_pr_files={"broken.0.json": text},
                )
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn("malformed benchmark round file", result.stdout)
                self.assertIn("broken.0.json", result.stdout)
                self.assertNotIn("Traceback", result.stderr)

    def test_process_baseline_is_not_compared(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.0] * 5, BASELINE: [0.9] * 5},
            base={SESSIONS: [2.0] * 5, BASELINE: [0.4] * 5},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_rounds_are_pooled_before_comparing(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.2, 2.2, 2.2, 2.2, 2.2]},
            base={SESSIONS: [1.0, 3.0, 2.0, 2.0, 2.0]},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("PASS  fx sessions --json", result.stdout)

    def test_missing_results_fail(self) -> None:
        result = self.run_checker(pr={})
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("No benchmark result files found", result.stdout)

    def test_margin_boundary_is_inclusive(self) -> None:
        base = 0.002
        at_margin = base * (1 + check_budgets.MAX_REGRESSION)
        just_over = at_margin * (1 + 1e-9)
        guard = 1.0
        self.assertIsNone(check_budgets.failure_reason(at_margin, base, guard))
        self.assertIsNotNone(check_budgets.failure_reason(just_over, base, guard))

    def test_non_linux_path_is_informational(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            passed = check_budgets.check_results(
                {SESSIONS: [9.0] * 5},
                {SESSIONS: [1.0] * 5, HELP: [1.0] * 5},
                "Darwin",
            )
        self.assertTrue(passed)
        self.assertIn("not evaluated on Darwin", output.getvalue())

    def test_margin_is_fifteen_percent(self) -> None:
        self.assertEqual(0.15, check_budgets.MAX_REGRESSION)

    def test_raw_guard_is_three_milliseconds(self) -> None:
        self.assertEqual(0.003, check_budgets.RAW_GUARD_SECONDS)

    def test_darwin_has_no_local_product_budget(self) -> None:
        self.assertIsNone(
            check_budgets.command_budget("Darwin", SESSIONS),
        )


if __name__ == "__main__":
    unittest.main()
