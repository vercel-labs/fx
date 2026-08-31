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


class BudgetContractTests(unittest.TestCase):
    def run_checker(self, results):
        with tempfile.TemporaryDirectory() as tmp:
            result_dir = pathlib.Path(tmp)
            for index, result in enumerate(results):
                (result_dir / f"{index}.json").write_text(json.dumps({"results": [result]}))
            env = os.environ.copy()
            env["FX_BENCH_RESULTS_GLOB"] = str(result_dir / "*.json")
            return subprocess.run(
                [sys.executable, str(MODULE_PATH)],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_linux_keeps_two_millisecond_raw_budget(self) -> None:
        self.assertEqual(
            check_budgets.command_budget("Linux", "fx sessions --json"),
            0.002,
        )
        self.assertEqual(
            check_budgets.command_budget("Linux", "fx config resolve --json"),
            0.002,
        )

    def test_darwin_has_no_local_product_budget(self) -> None:
        self.assertIsNone(
            check_budgets.command_budget("Darwin", "fx sessions --json"),
        )

    def test_budget_check_uses_raw_mean(self) -> None:
        self.assertFalse(check_budgets.within_budget(0.0021, 0.002))
        self.assertTrue(check_budgets.within_budget(0.002, 0.002))

    def test_missing_results_fail(self):
        result = self.run_checker([])
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("No benchmark result files found after excluding summary.json", result.stdout)


if __name__ == "__main__":
    unittest.main()
