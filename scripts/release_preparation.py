"""Qualify a release PR before building its frozen release snapshot."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import time

from scripts.release_candidate import SEMVER
from scripts.release_delivery import NATIVE_REPO, command, github


REQUIRED_CHECKS = {
    "Full suite (linux-x86_64)", "Full suite (linux-aarch64)",
    "Full suite (macos-x86_64)", "Full suite (macos-aarch64)",
    "Build & Test (ReleaseSafe)", "Startup Latency",
}


def prepared_readme(before: str, current: str, version: str) -> str:
    return re.sub(r"\bbash -s v" + re.escape(current) + r"(?![0-9A-Za-z.+-])",
                  f"bash -s v{version}", before)


def verify_version_only_change(before: str, after: str, changed: set[str], version: str) -> None:
    if not changed.issubset({"src/main.zig", "README.md", "CHANGELOG.md"}) or not {"src/main.zig", "CHANGELOG.md"}.issubset(changed):
        raise ValueError("release preparation contains changes beyond version and notes")
    pattern = r'^pub const version = "(' + SEMVER + r')";$'
    current = re.findall(pattern, before, re.MULTILINE)
    if len(current) != 1 or not re.fullmatch(SEMVER, version):
        raise ValueError("release source version is invalid")
    if tuple(map(int, version.split("."))) <= tuple(map(int, current[0].split("."))):
        raise ValueError("prepared version must advance the source version")
    expected = re.sub(pattern, f'pub const version = "{version}";', before, count=1, flags=re.MULTILINE)
    if expected != after:
        raise ValueError("release preparation changed executable code")


def inspect_release_pr(number: int, source_sha: str, root: pathlib.Path) -> dict:
    if type(number) is not int or number <= 0 or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("release PR and source SHA are invalid")
    pr = github(f"repos/{NATIVE_REPO}/pulls/{number}")
    if pr["head"]["repo"]["full_name"] != NATIVE_REPO or pr["head"]["sha"] != source_sha or pr["base"]["ref"] != "main":
        raise ValueError("release PR source does not match the requested snapshot")
    source = command(["git", "show", f"{source_sha}:src/main.zig"], cwd=root)
    versions = re.findall(r'^pub const version = "(' + SEMVER + r')";$', source, re.MULTILINE)
    if len(versions) != 1 or pr["head"]["ref"] == "main":
        raise ValueError("release preparation must use a stable version on a non-main branch")
    if not pr.get("merged"):
        if pr["state"] != "open":
            raise ValueError("release preparation PR is closed")
        base = command(["git", "merge-base", "origin/main", source_sha], cwd=root)
        before = command(["git", "show", f"{base}:src/main.zig"], cwd=root)
        changed = set(command(["git", "diff", "--name-only", base, source_sha], cwd=root).splitlines())
        verify_version_only_change(before, source, changed, versions[0])
        before_version = re.search(r'^pub const version = "([^"]+)";$', before, re.MULTILINE)[1]
        readme_before = command(["git", "show", f"{base}:README.md"], cwd=root)
        readme_after = command(["git", "show", f"{source_sha}:README.md"], cwd=root)
        if readme_after != prepared_readme(readme_before, before_version, versions[0]):
            raise ValueError("release README must contain only the prepared install-version change")
    return pr


def checks_pass(checks: list[dict]) -> bool:
    groups = {}
    for check in checks:
        if check["name"] == "Vercel Agent Review":
            continue
        groups.setdefault(check["name"], []).append(check)
    latest = {}
    for name, runs in groups.items():
        if len(runs) > 1:
            if any(not run.get("started_at") for run in runs):
                return False
            started = max(run["started_at"] for run in runs)
            newest = [run for run in runs if run["started_at"] == started]
            if len(newest) != 1:
                return False
            latest[name] = newest[0]
        else:
            latest[name] = runs[0]
    if any(check.get("conclusion") in ("failure", "cancelled", "timed_out", "action_required") for check in latest.values()):
        raise ValueError("release preparation CI failed")
    return (REQUIRED_CHECKS.issubset(latest)
            and all(latest[name].get("conclusion") == "success" for name in REQUIRED_CHECKS)
            and all(check.get("status") == "completed" and check.get("conclusion") in ("success", "skipped", "neutral") for check in latest.values()))


def wait_for_release_ci(number: int, source_sha: str, root: pathlib.Path) -> None:
    deadline = time.monotonic() + 150 * 60
    while time.monotonic() < deadline:
        inspect_release_pr(number, source_sha, root)
        checks = []
        page = 1
        while True:
            result = github(f"repos/{NATIVE_REPO}/commits/{source_sha}/check-runs?per_page=100&page={page}")
            checks.extend(result["check_runs"])
            if len(checks) >= result["total_count"]:
                break
            if not result["check_runs"] or page >= 20:
                raise ValueError("release check listing is incomplete")
            page += 1
        if checks_pass(checks):
            return
        print(f"Waiting for exact-source checks on release PR #{number}", flush=True)
        time.sleep(30)
    raise TimeoutError("release preparation checks exceeded the qualification window")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "wait"))
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        root = pathlib.Path.cwd()
        if args.action == "wait":
            wait_for_release_ci(args.pr, args.source_sha, root)
        else:
            inspect_release_pr(args.pr, args.source_sha, root)
        print(f"Qualified release preparation #{args.pr} at {args.source_sha}")
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Release qualification stopped: {error}\n")


if __name__ == "__main__":
    main()
