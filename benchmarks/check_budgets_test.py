#!/usr/bin/env python3

import importlib.util
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
    def run_checker(self, pr, base=None):
        with tempfile.TemporaryDirectory() as tmp:
            rounds_dir = pathlib.Path(tmp) / "rounds"
            for command, round_means_ms in pr.items():
                write_side(rounds_dir, "pr", command, round_means_ms)
            for command, round_means_ms in (base or {}).items():
                write_side(rounds_dir, "base", command, round_means_ms)
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
