#!/usr/bin/env python3
"""Enforce raw per-command wall-clock latency budgets against hyperfine results."""

import json
import glob
import os
import platform
import sys

LINUX_BUDGETS = {
    "fx (startup)": 0.002,
    "fx help": 0.002,
    "fx config schema --json": 0.002,
    "fx config capabilities --json": 0.002,
    "fx config resolve --json": 0.002,
    "fx status --json": 0.002,
    "fx background --json": 0.002,
    "fx doctor --json": 0.002,
    "fx sessions --json": 0.002,
}
DEFAULT_LINUX_BUDGET = 0.002


def command_budget(system_name, command):
    if system_name != "Linux":
        return None
    return LINUX_BUDGETS.get(command, DEFAULT_LINUX_BUDGET)


def within_budget(mean, budget):
    return mean <= budget


def check_results(result_files, system_name):
    filtered_files = [
        result_file
        for result_file in result_files
        if os.path.basename(result_file) != "summary.json"
    ]
    if not filtered_files:
        print("No benchmark result files found after excluding summary.json")
        return False

    failed = False
    for result_file in filtered_files:
        with open(result_file) as file:
            data = json.load(file)
        result = data["results"][0]
        name = result["command"]
        if name == "process baseline":
            print(
                f"  BASE  {name:<25} median={result['median'] * 1000:>5.1f}ms  "
                f"min={result['min'] * 1000:>5.1f}ms  mean={result['mean'] * 1000:>5.1f}ms"
            )
            continue
        mean = result["mean"]
        median = result["median"]
        budget = command_budget(system_name, name)
        ms = mean * 1000
        min_ms = result["min"] * 1000
        median_ms = median * 1000
        if budget is None:
            print(
                f"  INFO  {name:<25} mean={ms:>5.1f}ms  median={median_ms:>5.1f}ms  "
                f"min={min_ms:>5.1f}ms  (Linux budget: 2ms)"
            )
            continue
        limit_ms = budget * 1000
        ok = within_budget(mean, budget)
        tag = "PASS" if ok else "FAIL"
        print(
            f"  {tag}  {name:<25} mean={ms:>5.1f}ms  median={median_ms:>5.1f}ms  "
            f"min={min_ms:>5.1f}ms  (limit: {limit_ms:.0f}ms)"
        )
        if not ok:
            failed = True
    return not failed


def main():
    system_name = platform.system()
    result_files = sorted(
        glob.glob(
            os.environ.get(
                "FX_BENCH_RESULTS_GLOB",
                "benchmarks/results/*.json",
            )
        )
    )
    if check_results(result_files, system_name):
        if system_name != "Linux":
            print(
                f"\nLinux 2ms budget not evaluated on {system_name}; "
                "raw local means are informational"
            )
            return 0
        print("\nAll commands within budget")
        return 0
    print("\nLatency budget exceeded")
    return 1


if __name__ == "__main__":
    sys.exit(main())
