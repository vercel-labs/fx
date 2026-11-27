from __future__ import annotations

import io
import json
import os
import pathlib
import re
import subprocess
import tarfile
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "publish-libfx.yml"
WAIT_STEP = "Wait for npm to show every published package"
VERIFY_STEP = "Download and compare the immutable registry versions"
VERSION = "1.2.3"
PACKAGES = (
    "libfx",
    "@libfx/libfx-darwin-arm64",
    "@libfx/libfx-darwin-x64",
    "@libfx/libfx-linux-arm64-gnu",
    "@libfx/libfx-linux-x64-gnu",
)

# The fake npm reads one JSON plan: for each package, how many `npm view`
# calls answer "not found" before the version shows, or an error code that
# npm returns every time.
FAKE_NPM = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

args = sys.argv[1:]
if args[0] != "view" or "--json" not in args:
    raise SystemExit(f"unexpected npm arguments: {args}")
name, version = args[1].rsplit("@", 1)
plan = json.loads(pathlib.Path(os.environ["FAKE_NPM_PLAN"]).read_text())
calls_path = pathlib.Path(os.environ["FAKE_NPM_CALLS"])
calls = json.loads(calls_path.read_text()) if calls_path.exists() else {}
calls[name] = calls.get(name, 0) + 1
calls_path.write_text(json.dumps(calls))
entry = plan.get(name, {"hidden_calls": 0})
code = entry.get("error")
if code is None and calls[name] <= entry["hidden_calls"]:
    code = entry.get("hidden_code", "E404")
if code is not None:
    print(json.dumps({"error": {"code": code, "summary": f"{code} for {name}@{version}"}}))
    print(f"npm error code {code}", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(version))
'''

FAKE_SLEEP = r'''#!/usr/bin/env python3
import os
import pathlib

path = pathlib.Path(os.environ["FAKE_SLEEP_CALLS"])
count = int(path.read_text()) if path.exists() else 0
path.write_text(str(count + 1))
'''


def verify_job() -> str:
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    job = workflow.split("\n  verify-published:\n", 1)
    if len(job) != 2:
        raise AssertionError("publish-libfx.yml has no verify-published job")
    return job[1]


def step_script(job: str, step: str) -> str:
    match = re.search(
        rf"\n      - name: {re.escape(step)}\n(?:        .*\n)*?        run: \|\n((?:          .*\n|\n)+)",
        job,
    )
    if match is None:
        raise AssertionError(f"verify-published has no '{step}' step")
    return textwrap.dedent(match.group(1))


def add_package(path: pathlib.Path, name: str) -> None:
    manifest = json.dumps({"name": name, "version": VERSION}).encode()
    with tarfile.open(path, "w:gz") as archive:
        info = tarfile.TarInfo("package/package.json")
        info.size = len(manifest)
        archive.addfile(info, io.BytesIO(manifest))


class WaitForPublishedPackagesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.job = verify_job()
        self.script = step_script(self.job, WAIT_STEP)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name)
        tools = self.root / "tools"
        tools.mkdir()
        for name, body in (("npm", FAKE_NPM), ("sleep", FAKE_SLEEP)):
            (tools / name).write_text(body, encoding="utf-8")
            (tools / name).chmod(0o755)
        self.work = self.root / "work"
        (self.work / "libfx-native").mkdir(parents=True)
        add_package(self.work / "libfx-package.tgz", PACKAGES[0])
        for name in PACKAGES[1:]:
            add_package(self.work / "libfx-native" / f"{name[len('@libfx/'):]}.tgz", name)
        self.env = {
            **os.environ,
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "LIBFX_VERSION": VERSION,
            "FAKE_NPM_PLAN": str(self.root / "plan.json"),
            "FAKE_NPM_CALLS": str(self.root / "calls.json"),
            "FAKE_SLEEP_CALLS": str(self.root / "sleeps"),
        }

    def run_wait(self, plan: dict, deadline_seconds: int | None = None) -> subprocess.CompletedProcess[str]:
        (self.root / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        script = self.script
        if deadline_seconds is not None:
            script, count = re.subn(r"\bdeadline_seconds=\d+\n", f"deadline_seconds={deadline_seconds}\n", script)
            self.assertEqual(count, 1, "the wait must name its deadline once")
        return subprocess.run(
            ["bash", "-c", script],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def sleeps(self) -> int:
        path = self.root / "sleeps"
        return int(path.read_text()) if path.exists() else 0

    def calls(self) -> dict[str, int]:
        return json.loads((self.root / "calls.json").read_text())

    def test_the_wait_runs_before_the_registry_comparison(self) -> None:
        self.assertLess(self.job.index(f"- name: {WAIT_STEP}\n"), self.job.index(f"- name: {VERIFY_STEP}\n"))
        self.assertRegex(self.script, r"\bdeadline_seconds=600\n")

    def test_passes_at_once_when_npm_shows_every_package(self) -> None:
        result = self.run_wait({})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.sleeps(), 0)
        self.assertEqual(self.calls(), {name: 1 for name in PACKAGES})

    def test_waits_until_a_slow_package_and_libfx_show(self) -> None:
        result = self.run_wait({
            "libfx": {"hidden_calls": 2, "hidden_code": "ETARGET"},
            "@libfx/libfx-linux-arm64-gnu": {"hidden_calls": 4},
        })
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.sleeps(), 4)
        self.assertEqual(self.calls()["@libfx/libfx-linux-arm64-gnu"], 5)
        self.assertIn("npm does not show libfx@1.2.3 @libfx/libfx-linux-arm64-gnu@1.2.3 yet", result.stdout)
        self.assertIn("npm shows libfx @libfx/", result.stdout)

    def test_fails_at_the_deadline_naming_each_missing_package(self) -> None:
        result = self.run_wait({
            "@libfx/libfx-darwin-x64": {"hidden_calls": 10**9},
            "@libfx/libfx-linux-x64-gnu": {"hidden_calls": 10**9, "hidden_code": "ETARGET"},
        }, deadline_seconds=0)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.sleeps(), 0)
        self.assertEqual(self.calls(), {name: 1 for name in PACKAGES})
        self.assertIn(
            "::error::npm still does not show @libfx/libfx-darwin-x64@1.2.3 @libfx/libfx-linux-x64-gnu@1.2.3 after 0 seconds",
            result.stdout,
        )

    def test_fails_at_once_on_any_other_npm_error(self) -> None:
        result = self.run_wait({"@libfx/libfx-darwin-arm64": {"error": "E401"}})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.sleeps(), 0)
        self.assertIn("::error::npm view @libfx/libfx-darwin-arm64@1.2.3 failed with exit 1 and code 'E401'", result.stdout)
        self.assertIn("npm error code E401", result.stderr)


if __name__ == "__main__":
    unittest.main()
