from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "upstream_refresh.py"


def git(cwd: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


def run(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)


def commit(cwd: Path, message: str) -> str:
    return subprocess.check_output(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-am", message],
        cwd=cwd, text=True,
    ).strip()


class UpstreamRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="omifx-refresh-")
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        run(self.root, "init", "-q", "-b", "main").check_returncode()
        run(self.root, "config", "user.name", "test").check_returncode()
        run(self.root, "config", "user.email", "test@example.com").check_returncode()
        (self.root / "file").write_text("base\n")
        run(self.root, "add", "file").check_returncode()
        run(self.root, "commit", "-qm", "base").check_returncode()
        self.remote = Path(self.temp.name) / "upstream.git"
        run(Path(self.temp.name), "init", "--bare", "-q", str(self.remote)).check_returncode()
        run(self.root, "remote", "add", "upstream", str(self.remote)).check_returncode()
        run(self.root, "push", "-q", "-u", "upstream", "main").check_returncode()
        run(self.root, "checkout", "-qb", "upstream-merge").check_returncode()
        (self.root / "file").write_text("base\nomifx\n")
        run(self.root, "commit", "-qam", "oh-my-fx change").check_returncode()
        self.worktree = Path(self.temp.name) / "feature-worktree"
        run(self.root, "worktree", "add", "-q", "-b", "feature", str(self.worktree), "upstream-merge").check_returncode()
        (self.worktree / "feature").write_text("feature\n")
        run(self.worktree, "add", "feature").check_returncode()
        run(self.worktree, "commit", "-qm", "feature change").check_returncode()
        run(self.root, "push", "-q", "upstream", "main").check_returncode()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_plan_pins_one_source_and_lists_worktrees(self) -> None:
        result = subprocess.run(
            ["python3", str(SCRIPT), "plan", "--root", str(self.root), "--no-fetch"],
            text=True, capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        plan_path = Path(next(line[6:] for line in result.stdout.splitlines() if line.startswith("plan: ")))
        payload = json.loads(plan_path.read_text())
        self.assertEqual(git(self.root, "rev-parse", "upstream/main"), payload["source"])
        self.assertEqual({"upstream-merge", "feature"}, {entry["branch"] for entry in payload["entries"] if entry["branch"]})
        self.assertEqual("ready", payload["phase"])

    def test_apply_rebases_all_clean_worktrees_onto_pinned_source(self) -> None:
        upstream = self.remote
        source_repo = Path(self.temp.name) / "source"
        run(Path(self.temp.name), "clone", "-q", str(upstream), str(source_repo)).check_returncode()
        run(source_repo, "config", "user.name", "test").check_returncode()
        run(source_repo, "config", "user.email", "test@example.com").check_returncode()
        (source_repo / "upstream").write_text("upstream\n")
        run(source_repo, "add", "upstream").check_returncode()
        run(source_repo, "commit", "-qm", "upstream change").check_returncode()
        run(source_repo, "push", "-q", "origin", "main").check_returncode()
        run(self.root, "fetch", "-q", "upstream", "main").check_returncode()
        plan = subprocess.run(
            ["python3", str(SCRIPT), "plan", "--root", str(self.root), "--no-fetch"],
            text=True, capture_output=True,
        )
        plan_path = Path(next(line[6:] for line in plan.stdout.splitlines() if line.startswith("plan: ")))
        applied = subprocess.run(
            ["python3", str(SCRIPT), "apply", "--root", str(self.root), "--plan", str(plan_path)],
            text=True, capture_output=True,
        )
        self.assertEqual(0, applied.returncode, applied.stderr)
        integration = payload_integration = json.loads(plan_path.read_text())["integration"]
        for entry in json.loads(plan_path.read_text())["entries"]:
            if entry["status"] == "updated":
                self.assertEqual(0, run(self.root, "merge-base", "--is-ancestor", integration, entry["branch"]).returncode)
        self.assertEqual(0, run(self.root, "for-each-ref", "--format=%(refname)", "refs/backup/omifx-upstream-refresh").returncode)


    def test_plan_marks_dirty_worktree_without_mutating_it(self) -> None:
        marker = self.worktree / "uncommitted"
        marker.write_text("keep\n")
        result = subprocess.run(["python3", str(SCRIPT), "prepare", "--root", str(self.root), "--no-fetch"], text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        plan_path = Path(next(line[6:] for line in result.stdout.splitlines() if line.startswith("plan: ")))
        payload = json.loads(plan_path.read_text())
        feature = next(entry for entry in payload["entries"] if entry["branch"] == "feature")
        self.assertEqual("skipped-dirty", feature["status"])
        self.assertTrue(marker.exists())

    def test_plan_reports_detached_worktree(self) -> None:
        detached = Path(self.temp.name) / "detached"
        run(self.root, "worktree", "add", "-q", "--detach", str(detached), "HEAD").check_returncode()
        result = subprocess.run(["python3", str(SCRIPT), "prepare", "--root", str(self.root), "--no-fetch"], text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        plan_path = Path(next(line[6:] for line in result.stdout.splitlines() if line.startswith("plan: ")))
        payload = json.loads(plan_path.read_text())
        detached_entry = next(entry for entry in payload["entries"] if entry["worktree"] == str(detached))
        self.assertEqual("skipped-detached", detached_entry["status"])
if __name__ == "__main__":
    unittest.main()
