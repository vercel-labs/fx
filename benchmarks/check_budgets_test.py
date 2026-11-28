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


def command_file_name(command):
    return command.replace(" ", "_").replace("/", "_")


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
        (side_dir / f"{command_file_name(command)}.{index}.json").write_text(
            json.dumps({"results": [result]})
        )


def write_raw_side(rounds_dir, side, command, rounds_ms):
    """Write one round file per list of run times, in milliseconds."""
    side_dir = rounds_dir / side
    side_dir.mkdir(parents=True, exist_ok=True)
    for index, times_ms in enumerate(rounds_ms):
        times = [value / 1000.0 for value in times_ms]
        result = {
            "command": command,
            "mean": sum(times) / len(times),
            "times": times,
        }
        (side_dir / f"{command_file_name(command)}.{index}.json").write_text(
            json.dumps({"results": [result]})
        )


class BudgetComparisonTests(unittest.TestCase):
    def run_checker(self, pr=None, base=None, raw_pr_files=None, pr_raw=None, base_raw=None):
        with tempfile.TemporaryDirectory() as tmp:
            rounds_dir = pathlib.Path(tmp) / "rounds"
            for command, round_means_ms in (pr or {}).items():
                write_side(rounds_dir, "pr", command, round_means_ms)
            for command, round_means_ms in (base or {}).items():
                write_side(rounds_dir, "base", command, round_means_ms)
            for command, rounds_ms in (pr_raw or {}).items():
                write_raw_side(rounds_dir, "pr", command, rounds_ms)
            for command, rounds_ms in (base_raw or {}).items():
                write_raw_side(rounds_dir, "base", command, rounds_ms)
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

    def test_twenty_five_percent_slower_fails(self) -> None:
        result = self.run_checker(
            pr={SESSIONS: [2.5] * 5},
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

    def test_outlier_fails_the_mean_rule_but_not_the_median(self) -> None:
        # Nine runs at 1 ms and one at 10 ms: the mean is 1.9 ms, the median 1 ms.
        result = self.run_checker(
            pr_raw={SESSIONS: [[1.0] * 9 + [10.0]]},
            base_raw={SESSIONS: [[1.0] * 10]},
        )
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("FAIL  fx sessions --json", result.stdout)
        median_line = next(
            line
            for line in result.stdout.splitlines()
            if "median" in line and SESSIONS in line
        )
        self.assertIn("change=+0.0%", median_line)

    def test_margin_is_twenty_percent(self) -> None:
        self.assertEqual(0.20, check_budgets.MAX_REGRESSION)

    def test_raw_guard_is_three_milliseconds(self) -> None:
        self.assertEqual(0.003, check_budgets.RAW_GUARD_SECONDS)

    def test_darwin_has_no_local_product_budget(self) -> None:
        self.assertIsNone(
            check_budgets.command_budget("Darwin", SESSIONS),
        )


class StatisticsTests(unittest.TestCase):
    def test_median_of_odd_count_is_the_middle_value(self) -> None:
        self.assertEqual(3.0, check_budgets.median([5.0, 1.0, 3.0, 4.0, 2.0]))

    def test_median_of_even_count_averages_the_middle_pair(self) -> None:
        self.assertEqual(2.5, check_budgets.median([4.0, 1.0, 3.0, 2.0]))

    def test_outlier_moves_the_mean_but_not_the_median_or_min(self) -> None:
        stats = check_budgets.summarize([1.0, 1.0, 1.0, 1.0, 10.0])
        self.assertAlmostEqual(2.8, stats["mean"])
        self.assertEqual(1.0, stats["median"])
        self.assertEqual(1.0, stats["min"])

    def test_pooled_median_is_taken_over_every_run(self) -> None:
        # Pooling gives [1, 1, 1, 10, 10, 10, 10, 10]: median 10 ms, min 1 ms.
        # The mean of the two round medians would be 5.5 ms, so this tells them apart.
        with tempfile.TemporaryDirectory() as tmp:
            rounds_dir = pathlib.Path(tmp)
            write_raw_side(rounds_dir, "pr", SESSIONS, [[1.0, 1.0, 1.0], [10.0] * 5])
            pooled = check_budgets.load_pooled(str(rounds_dir / "pr"))
        stats = check_budgets.summarize(pooled[SESSIONS])
        self.assertAlmostEqual(0.010, stats["median"])
        self.assertAlmostEqual(0.001, stats["min"])


if __name__ == "__main__":
    unittest.main()
