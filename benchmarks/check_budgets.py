#!/usr/bin/env python3
"""Compare fx's startup timings with the base commit's, measured on the same host.

Each round file is a hyperfine export. startup.sh measures the base and the PR
binary in alternating rounds on one runner, so a slow host slows both. A command
fails when its PR mean is more than MAX_REGRESSION above the base mean, or when
its PR mean is above RAW_GUARD_SECONDS. The raw guard bounds slow creep across
many changes: each change may not slow fx by the margin, and fx may not drift
past the guard in total.
"""

import glob
import json
import os
import platform
import sys


MAX_REGRESSION = 0.15
RAW_GUARD_SECONDS = 0.003
PROCESS_BASELINE = "process baseline"
ROUNDS_DIR_ENV = "FX_BENCH_ROUNDS_DIR"
DEFAULT_ROUNDS_DIR = "benchmarks/results/rounds"
PR_SIDE = "pr"
BASE_SIDE = "base"


class RoundFileError(ValueError):
    """A round file that is not a readable hyperfine export."""


def command_budget(system_name, command):
    if system_name != "Linux":
        return None
    return RAW_GUARD_SECONDS


def load_pooled(side_dir):
    """Return {command: [run seconds]} pooled over every round file of one side."""
    pooled = {}
    for path in sorted(glob.glob(os.path.join(side_dir, "*.json"))):
        try:
            with open(path) as file:
                result = json.load(file)["results"][0]
                command = result["command"]
                times = [float(t) for t in result["times"]]
        except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
            raise RoundFileError(f"{path}: {error}") from error
        if not times:
            raise RoundFileError(f"{path}: no run times")
        pooled.setdefault(command, []).extend(times)
    return pooled


def mean(samples):
    return sum(samples) / len(samples)


def print_baseline(pr, base):
    if PROCESS_BASELINE not in pr or PROCESS_BASELINE not in base:
        return
    print(
        f"  BASE  {PROCESS_BASELINE:<25} pr={mean(pr[PROCESS_BASELINE]) * 1000:>5.2f}ms  "
        f"base={mean(base[PROCESS_BASELINE]) * 1000:>5.2f}ms  (not compared)"
    )


def failure_reason(pr_mean, base_mean, guard):
    if pr_mean > guard:
        return f"over the raw guard of {guard * 1000:.0f}ms"
    if pr_mean > base_mean * (1 + MAX_REGRESSION):
        return f"more than {MAX_REGRESSION:.0%} above the base"
    return None


def check_command(name, pr_times, base_times, guard):
    if not base_times:
        print(f"  FAIL  {name:<25} no base result for {name}, so the margin cannot be checked")
        return False
    base_mean = mean(base_times)
    if base_mean <= 0:
        print(f"  FAIL  {name:<25} base mean is not positive, so the margin cannot be checked")
        return False
    pr_mean = mean(pr_times)
    reason = failure_reason(pr_mean, base_mean, guard)
    tag = "FAIL" if reason else "PASS"
    suffix = f"  ({reason})" if reason else ""
    print(
        f"  {tag}  {name:<25} pr={pr_mean * 1000:>5.2f}ms  base={base_mean * 1000:>5.2f}ms  "
        f"change={pr_mean / base_mean - 1:+.1%}  "
        f"(margin {MAX_REGRESSION:.0%}, raw guard {guard * 1000:.0f}ms){suffix}"
    )
    return reason is None


def check_results(pr, base, system_name):
    if not pr:
        print("No benchmark result files found")
        return False
    print_baseline(pr, base)
    if system_name != "Linux":
        print(f"\nLinux budget not evaluated on {system_name}; raw local means are informational")
        return True
    failed = False
    for name in sorted(set(pr) | set(base)):
        if name == PROCESS_BASELINE:
            continue
        if name not in pr:
            print(
                f"  FAIL  {name:<25} no PR result for {name}, "
                "so a renamed or dropped benchmark cannot pass silently"
            )
            failed = True
            continue
        guard = command_budget(system_name, name)
        if not check_command(name, pr[name], base.get(name, []), guard):
            failed = True
    return not failed


def main():
    rounds_dir = os.environ.get(ROUNDS_DIR_ENV, DEFAULT_ROUNDS_DIR)
    try:
        pr = load_pooled(os.path.join(rounds_dir, PR_SIDE))
        base = load_pooled(os.path.join(rounds_dir, BASE_SIDE))
    except RoundFileError as error:
        print(f"FAIL  malformed benchmark round file {error}")
        return 1
    if check_results(pr, base, platform.system()):
        print("\nAll commands within budget")
        return 0
    print("\nLatency budget exceeded")
    return 1


if __name__ == "__main__":
    sys.exit(main())
