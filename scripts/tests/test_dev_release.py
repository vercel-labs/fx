from __future__ import annotations

import os
import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEV_RELEASE_PATH = REPO_ROOT / ".github" / "workflows" / "dev-release.yml"
CI_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
PLAN_STEP = "Decide whether this commit needs a dev build"
WAIT_STEP = "Wait until releases.fx.sh serves this commit"
BUILD_SHA = "1111111111111111111111111111111111111111"
OLD_SHA = "2222222222222222222222222222222222222222"

# The jobs a dev build waits for. The rest of CI (the durable-session model
# check, the TLA+ models, the package guards, Shellcheck, and the aggregate
# checks) still runs on every push to main, but a dev build does not wait.
DEV_GATE_JOBS = {
    "zig_mode",
    "build",
    "sdk-wasm",
    "sdk-napi",
    "sdk-node-wasm",
    "sdk-node-napi",
    "sdk-browser-wasm",
    "e2e_mode",
    "e2e_conformance",
    "e2e",
}

# A fake curl for the steps that read dev.json. It answers each call with the
# next line of $FAKE_DEV_JSON_ANSWERS and repeats the last line after that.
# "fail" makes the call fail like a network error.
FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

if not any(arg.endswith("/dev.json") for arg in sys.argv[1:]):
    raise SystemExit(f"unexpected curl arguments: {sys.argv[1:]}")
answers = pathlib.Path(os.environ["FAKE_DEV_JSON_ANSWERS"]).read_text().split()
calls_path = pathlib.Path(os.environ["FAKE_CURL_CALLS"])
calls = int(calls_path.read_text()) if calls_path.exists() else 0
calls_path.write_text(str(calls + 1))
answer = answers[min(calls, len(answers) - 1)]
if answer == "fail":
    print("curl: (28) Operation timed out", file=sys.stderr)
    raise SystemExit(28)
print(json.dumps({"version": "0.0.0", "commit": answer}))
'''

FAKE_SLEEP = r'''#!/usr/bin/env python3
import os
import pathlib

path = pathlib.Path(os.environ["FAKE_SLEEP_CALLS"])
count = int(path.read_text()) if path.exists() else 0
path.write_text(str(count + 1))
'''


def top_level_block(workflow: str, key: str) -> str:
    match = re.search(rf"^{re.escape(key)}:\n((?:[ \n].*\n?)*)", workflow, re.MULTILINE)
    if match is None:
        raise AssertionError(f"the workflow has no top-level '{key}'")
    return match.group(1)


def jobs(workflow: str) -> dict[str, str]:
    body = top_level_block(workflow, "jobs")
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\n", body, flags=re.MULTILINE)
    return dict(zip(parts[1::2], parts[2::2]))


def job_key(job: str, key: str) -> str:
    match = re.search(rf"^    {re.escape(key)}:(.*(?:\n      .*)*)", job, re.MULTILINE)
    return "" if match is None else match.group(1).strip()


def needs(job: str) -> set[str]:
    value = job_key(job, "needs")
    return set(re.findall(r"[A-Za-z0-9_-]+", value))


def step_script(job: str, step: str) -> str:
    match = re.search(
        rf"\n      - name: {re.escape(step)}\n(?:        .*\n)*?        run: \|\n((?:          .*\n|\n)+)",
        job,
    )
    if match is None:
        raise AssertionError(f"the job has no '{step}' step")
    return textwrap.dedent(match.group(1))


def artifact_names(workflow: str, action: str) -> list[str]:
    return re.findall(
        rf"uses: {re.escape(action)}\n\s+with:\n\s+name: (\S+)",
        workflow,
    )


class DevReleaseScheduleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = DEV_RELEASE_PATH.read_text(encoding="utf-8")
        self.jobs = jobs(self.workflow)

    def test_runs_twice_an_hour_instead_of_after_ci(self) -> None:
        triggers = top_level_block(self.workflow, "on")
        self.assertNotIn("workflow_run", self.workflow)
        cron = re.search(r'- cron: "([^"]+)"', triggers)
        self.assertIsNotNone(cron, "Dev Release must run on a schedule")
        minute, *rest = cron.group(1).split()
        self.assertEqual(rest, ["*", "*", "*", "*"])
        minutes = [int(value) for value in minute.split(",")]
        self.assertEqual(len(minutes), 2)
        self.assertEqual(minutes[1] - minutes[0], 30)
        self.assertIn("workflow_dispatch:", triggers)

    def test_runs_for_different_commits_overlap(self) -> None:
        concurrency = top_level_block(self.workflow, "concurrency")
        self.assertIn("github.sha", concurrency)
        self.assertIn("cancel-in-progress: false", concurrency)

    def test_the_gate_is_ci_in_dev_gate_mode(self) -> None:
        gate = self.jobs["gate"]
        self.assertEqual(job_key(gate, "uses"), "./.github/workflows/ci.yml")
        self.assertRegex(job_key(gate, "with"), r"dev_gate: true")
        self.assertEqual(needs(gate), {"plan"})

    def test_publish_waits_for_the_gate_and_runs_only_from_the_schedule_on_main(self) -> None:
        publish = self.jobs["publish"]
        self.assertEqual(needs(publish), {"gate", "build", "web"})
        condition = job_key(publish, "if")
        self.assertIn("github.event_name == 'schedule'", condition)
        self.assertIn("github.ref == 'refs/heads/main'", condition)
        self.assertNotIn("||", condition)

    def test_publishes_go_one_at_a_time(self) -> None:
        publish = self.jobs["publish"]
        concurrency = job_key(publish, "concurrency")
        self.assertIn("group: dev-release-publish", concurrency)
        self.assertIn("cancel-in-progress: false", concurrency)
        self.assertNotIn("github.sha", concurrency)

    def test_publish_builds_and_names_the_commit_the_gate_tested(self) -> None:
        publish = self.jobs["publish"]
        self.assertIn("RELEASE_SHA: ${{ github.sha }}", publish)
        for name in ("build", "web", "publish"):
            self.assertNotRegex(self.jobs[name], r"ref: \$\{\{ (?!github\.sha)", name)

    def test_publish_downloads_only_its_own_artifacts(self) -> None:
        own = artifact_names(self.workflow, "actions/upload-artifact@v4")
        self.assertTrue(own)
        for name in own:
            self.assertTrue(name.startswith("dev-"), name)
        for name in artifact_names(CI_PATH.read_text(encoding="utf-8"), "actions/upload-artifact@v4"):
            self.assertFalse(name.startswith("dev-"), f"ci.yml artifact {name} would reach the dev publish")
        download = re.search(r"uses: actions/download-artifact@v4\n\s+with:\n((?:\s{10}.*\n)+)", self.jobs["publish"])
        self.assertIsNotNone(download)
        self.assertIn("pattern: dev-*", download.group(1))

    def test_build_and_web_skip_when_the_plan_says_no(self) -> None:
        for name in ("gate", "build", "web"):
            self.assertIn("plan", needs(self.jobs[name]), name)
            self.assertIn("needs.plan.outputs.needed == 'true'", job_key(self.jobs[name], "if"), name)


class CiDevGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = CI_PATH.read_text(encoding="utf-8")
        self.jobs = jobs(self.workflow)

    def test_ci_can_be_called_with_a_dev_gate_input(self) -> None:
        triggers = top_level_block(self.workflow, "on")
        call = re.search(r"  workflow_call:\n((?:    .*\n)+)", triggers)
        self.assertIsNotNone(call)
        self.assertRegex(call.group(1), r"dev_gate:\n\s+.*\n?(?:\s+.*\n)*?\s+type: boolean")

    def test_dev_gate_runs_exactly_the_approved_jobs(self) -> None:
        ran = {name for name, job in self.jobs.items() if "!inputs.dev_gate" not in job_key(job, "if")}
        self.assertEqual(ran, DEV_GATE_JOBS)

    def test_no_dev_gate_job_waits_for_a_skipped_job(self) -> None:
        for name in DEV_GATE_JOBS:
            self.assertLessEqual(needs(self.jobs[name]), DEV_GATE_JOBS, name)

    def test_required_checks_keep_their_names(self) -> None:
        names = {job_key(job, "name") for job in self.jobs.values()}
        for required in ("Build & Test", "E2E (deterministic)", "Shellcheck"):
            self.assertIn(required, names)

    def test_dev_gate_gets_its_own_concurrency_group(self) -> None:
        # A called workflow's concurrency uses the caller's github context, so
        # without its own group a scheduled gate would join the queue of the
        # push runs on main and replace the one that waits.
        concurrency = top_level_block(self.workflow, "concurrency")
        group = re.search(r"group: (.*)", concurrency).group(1)
        self.assertRegex(group, r"inputs\.dev_gate && format\('ci-dev-gate-\{0\}', github\.run_id\)")
        cancel = re.search(r"cancel-in-progress: (.*)", concurrency).group(1)
        self.assertIn("github.event_name == 'pull_request'", cancel)
        self.assertIn("!inputs.dev_gate", cancel)

    def test_unit_job_runs_this_test(self) -> None:
        self.assertTrue("scripts.tests.test_dev_release" in self.workflow, "ci.yml must run this test")


class DevReleaseStepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = jobs(DEV_RELEASE_PATH.read_text(encoding="utf-8"))
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name)
        tools = self.root / "tools"
        tools.mkdir()
        for name, body in (("curl", FAKE_CURL), ("sleep", FAKE_SLEEP)):
            (tools / name).write_text(body, encoding="utf-8")
            (tools / name).chmod(0o755)
        self.output = self.root / "github_output"
        self.env = {
            **os.environ,
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_OUTPUT": str(self.output),
            "FAKE_DEV_JSON_ANSWERS": str(self.root / "answers"),
            "FAKE_CURL_CALLS": str(self.root / "curl_calls"),
            "FAKE_SLEEP_CALLS": str(self.root / "sleep_calls"),
        }

    def run_step(self, job: str, step: str, answers: list[str], **env: str) -> subprocess.CompletedProcess[str]:
        (self.root / "answers").write_text("\n".join(answers), encoding="utf-8")
        return subprocess.run(
            ["bash", "-c", step_script(self.jobs[job], step)],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            timeout=60,
        )

    def outputs(self) -> str:
        return self.output.read_text() if self.output.exists() else ""

    def calls(self, name: str) -> int:
        path = self.root / f"{name}_calls"
        return int(path.read_text()) if path.exists() else 0

    def plan(self, answers: list[str], event: str = "schedule") -> subprocess.CompletedProcess[str]:
        return self.run_step("plan", PLAN_STEP, answers, EVENT_NAME=event, BUILD_SHA=BUILD_SHA)

    def test_plan_skips_a_commit_the_channel_already_names(self) -> None:
        result = self.plan([BUILD_SHA])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("needed=false", self.outputs())

    def test_plan_builds_a_newer_commit(self) -> None:
        result = self.plan([OLD_SHA])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("needed=true", self.outputs())

    def test_plan_builds_when_dev_json_cannot_be_read(self) -> None:
        result = self.plan(["fail"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("needed=true", self.outputs())

    def test_plan_always_runs_the_gate_for_a_manual_dispatch(self) -> None:
        result = self.plan([BUILD_SHA], event="workflow_dispatch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("needed=true", self.outputs())
        self.assertEqual(self.calls("curl"), 0)

    def wait(self, answers: list[str]) -> subprocess.CompletedProcess[str]:
        return self.run_step("publish", WAIT_STEP, answers, RELEASE_SHA=BUILD_SHA)

    def test_wait_ends_once_the_cdn_serves_this_commit(self) -> None:
        result = self.wait([OLD_SHA, "fail", BUILD_SHA])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("curl"), 3)
        self.assertEqual(self.calls("sleep"), 2)

    def test_wait_fails_at_its_deadline(self) -> None:
        result = self.wait([OLD_SHA])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still names", result.stdout + result.stderr)
        self.assertGreater(self.calls("curl"), 1)


if __name__ == "__main__":
    unittest.main()
