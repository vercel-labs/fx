from __future__ import annotations

import contextlib
import base64
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from scripts import prepare_release_notes as notes
from scripts import release_preparation
from scripts.tests.test_release_metadata import workflow_script

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BODY = "**fx keeps saved conversations available after a restart.**\n\n### Bug Fixes\n\n- Saved conversations now resume after a restart.\n"
SOURCE = 'pub const version = "0.0.9";\nconst compiled = 1;\n'
README = "curl installer | bash -s v0.0.9\n"


def changelog(version="0.0.10", body=BODY):
    return f"# fx\n\n## {version}\n\n<!-- release:start -->\n\n{body}\n<!-- release:end -->\n\n## 0.0.8\n\nOlder notes.\n"


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release-local-notes-")
        self.addCleanup(temporary.cleanup)
        self.directory = pathlib.Path(temporary.name)
        self.root = self.directory / "checkout"
        self.root.mkdir()
        self.environment = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull,
                            "GIT_CONFIG_NOSYSTEM": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        self.git("init", "--quiet", "--bare", str(self.directory / "origin.git"))
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.name", "Release Fixture")
        self.git("config", "user.email", "release@example.com")
        self.git("config", "commit.gpgsign", "false")
        (self.root / "src").mkdir()
        (self.root / "src/main.zig").write_text(SOURCE)
        (self.root / "README.md").write_text(README)
        (self.root / "CHANGELOG.md").write_text(changelog("0.0.9"))
        self.git("add", "src/main.zig", "README.md", "CHANGELOG.md")
        self.git("commit", "--quiet", "-m", "Base release")
        self.git("remote", "add", "origin", str(self.directory / "origin.git"))
        self.git("push", "--quiet", "-u", "origin", "main")
        self.base = self.git("rev-parse", "HEAD")
        self.pr = dict(number=42, state="OPEN", headRefName="release/local-notes",
                       headRefOid="", baseRefName="main", isCrossRepository=False,
                       isDraft=False, labels=[])

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.environment,
                                       stderr=subprocess.PIPE, text=True).strip()

    def commit_notes(self, text=None, source=SOURCE, extra=False):
        arguments = ["switch", "--quiet"]
        if not self.pr["headRefOid"]:
            arguments.append("-c")
        self.git(*arguments, self.pr["headRefName"])
        (self.root / "CHANGELOG.md").write_text(changelog() if text is None else text)
        (self.root / "src/main.zig").write_text(source)
        self.git("add", "src/main.zig", "CHANGELOG.md")
        if extra:
            (self.root / "unexpected.py").write_text("raise RuntimeError('not release input')\n")
            self.git("add", "unexpected.py")
        self.git("commit", "--quiet", "--allow-empty", "-m", "Write local notes")
        self.git("push", "--quiet", "origin", self.pr["headRefName"])
        self.pr["headRefOid"] = self.git("rev-parse", "HEAD")
        self.git("switch", "--quiet", "main")

    def command(self, *args, **kwargs):
        if args[0] == "gh":
            self.assertEqual(("gh", "pr", "view", "42"), args[:4])
            return json.dumps(self.pr)
        return self.original_command(*args, **kwargs)

    @contextlib.contextmanager
    def checkout(self):
        self.original_command = notes.command
        with contextlib.chdir(self.root), mock.patch.object(notes, "command", side_effect=self.command), \
                mock.patch("urllib.request.urlopen", side_effect=AssertionError("no model requests")):
            yield

    def files(self):
        return {path: (self.root / path).read_bytes() for path in ("src/main.zig", "README.md", "CHANGELOG.md")}

    def test_cli_prepares_a_local_changelog_without_a_model(self):
        self.commit_notes()
        executables = self.directory / "bin"
        executables.mkdir()
        metadata = self.directory / "pr.json"
        metadata.write_text(json.dumps(self.pr))
        gh = executables / "gh"
        gh.write_text(f"#!{sys.executable}\nimport os,pathlib\nprint(pathlib.Path(os.environ['FX_TEST_PR']).read_text())\n")
        gh.chmod(0o755)
        environment = {**self.environment, "PATH": f"{executables}{os.pathsep}{os.environ['PATH']}",
                       "PYTHONPATH": str(REPO_ROOT), "FX_TEST_PR": str(metadata),
                       "GITHUB_OUTPUT": str(self.directory / "outputs")}
        environment.pop("AI_GATEWAY_API_KEY", None)
        plan_path = self.directory / "plan.json"
        before = self.files()
        for arguments in (["plan", "--pr", "42"], ["apply"]):
            result = subprocess.run([sys.executable, "-m", "scripts.prepare_release_notes", *arguments,
                                     "--plan", str(plan_path)], cwd=self.root, env=environment,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        plan = json.loads(plan_path.read_text())
        self.assertEqual("0.0.10", plan["version"])
        self.assertEqual(self.pr["headRefOid"], plan["expected_head"])
        self.assertEqual("release/local-notes", plan["branch"])
        self.assertEqual(SOURCE.replace("0.0.9", "0.0.10"), (self.root / "src/main.zig").read_text())
        self.assertEqual(README.replace("0.0.9", "0.0.10"), (self.root / "README.md").read_text())
        self.assertEqual(before["CHANGELOG.md"], (self.root / "CHANGELOG.md").read_bytes())
        self.assertEqual(self.base, self.git("rev-parse", "HEAD"))
        self.assertIn("pr_number=42\n", (self.directory / "outputs").read_text())

    def test_plan_preserves_handwritten_notes_and_all_files(self):
        authored = changelog(body=BODY.replace("restart.\n", "restart.  \n") + "\n\n")
        self.commit_notes(authored)
        before = self.files()
        with self.checkout():
            plan = notes.make_plan(42)
        self.assertTrue(plan["prepare"])
        self.assertEqual("0.0.10", plan["version"])
        self.assertEqual(before, self.files())
        actual = subprocess.check_output(["git", "show", f"{self.pr['headRefOid']}:CHANGELOG.md"], cwd=self.root)
        self.assertEqual(authored.encode(), actual)

    def test_already_aligned_release_is_reused_without_a_commit(self):
        self.commit_notes(source=SOURCE.replace("0.0.9", "0.0.10"))
        self.git("switch", "--quiet", self.pr["headRefName"])
        (self.root / "README.md").write_text(README.replace("0.0.9", "0.0.10"))
        self.git("add", "README.md")
        self.git("commit", "--quiet", "-m", "Align install example")
        self.git("push", "--quiet", "origin", self.pr["headRefName"])
        self.pr["headRefOid"] = self.git("rev-parse", "HEAD")
        self.git("switch", "--quiet", "main")
        before = self.files()
        with self.checkout():
            plan = notes.make_plan(42)
            self.assertFalse(plan["prepare"])
            notes.apply_version(plan)
        self.assertEqual(before, self.files())

    def test_missing_or_invalid_notes_fail_without_writes(self):
        for text in ("# fx\n", changelog("0.0.9"), changelog("0.0.10-dev"),
                     changelog().replace("<!-- release:end -->", ""),
                     changelog() + "<!-- release:start -->", changelog(body="")):
            with self.subTest(text=text):
                self.commit_notes(text)
                before = self.files()
                with self.checkout(), self.assertRaises(ValueError):
                    notes.make_plan(42)
                self.assertEqual(before, self.files())

    def test_executable_or_unrelated_changes_are_rejected(self):
        for source, extra in ((SOURCE + "run_unreviewed_code();\n", False), (SOURCE, True)):
            self.commit_notes(source=source, extra=extra)
            before = self.files()
            with self.checkout(), self.assertRaises(ValueError):
                notes.make_plan(42)
            self.assertEqual(before, self.files())

    def test_foreign_closed_draft_and_wrongly_labeled_prs_are_rejected(self):
        self.commit_notes()
        for change in ({"state": "CLOSED"}, {"state": "MERGED"}, {"isCrossRepository": True},
                       {"isDraft": True}, {"baseRefName": "other"}, {"headRefName": "main"},
                       {"headRefOid": "bad-sha"}, {"labels": [{"name": "type: bug"}]}):
            with self.subTest(change=change), mock.patch.dict(self.pr, change), self.checkout(), self.assertRaises(ValueError):
                notes.make_plan(42)

    def test_changed_pr_head_stops_before_applying_versions(self):
        self.commit_notes()
        with self.checkout():
            plan = notes.make_plan(42)
        self.commit_notes(changelog(body=BODY.replace("restart", "login")))
        before = self.files()
        with self.checkout(), self.assertRaisesRegex(ValueError, "changed"):
            notes.apply_version(plan)
        self.assertEqual(before, self.files())

    def test_invalid_pr_number_is_rejected_before_inspection(self):
        for value in (0, -1, True, "42"):
            with self.subTest(value=value), mock.patch.object(notes, "command") as read, self.assertRaises(ValueError):
                notes.make_plan(value)
            read.assert_not_called()

    def test_unversioned_readme_remains_unchanged(self):
        unversioned = "curl installer | bash\n"
        (self.root / "README.md").write_text(unversioned)
        self.git("add", "README.md")
        self.git("commit", "--quiet", "-m", "Use the stable installer")
        self.git("push", "--quiet", "origin", "main")
        self.commit_notes()
        with self.checkout():
            notes.apply_version(notes.make_plan(42))
        self.assertEqual(unversioned, (self.root / "README.md").read_text())

    def test_wrong_readme_pin_and_unrelated_edits_are_rejected(self):
        self.commit_notes(source=SOURCE.replace("0.0.9", "0.0.10"))
        for readme in (README.replace("0.0.9", "0.0.8"), README + "Unrelated documentation.\n"):
            self.git("switch", "--quiet", self.pr["headRefName"])
            (self.root / "README.md").write_text(readme)
            self.git("add", "README.md")
            self.git("commit", "--quiet", "-m", "Change README")
            self.git("push", "--quiet", "origin", self.pr["headRefName"])
            self.pr["headRefOid"] = self.git("rev-parse", "HEAD")
            self.git("switch", "--quiet", "main")
            before = self.files()
            with self.subTest(readme=readme), self.checkout(), self.assertRaisesRegex(ValueError, "README"):
                notes.make_plan(42)
            self.assertEqual(before, self.files())

    def test_approved_format_is_validated_without_rewriting(self):
        approved = (REPO_ROOT / "CHANGELOG.md").read_text().split("## 0.0.9\n", 1)[1].split("\n## ", 1)[0]
        notes.validate_body(approved.replace("<!-- release:start -->", "").replace("<!-- release:end -->", ""))
        for body in (BODY.replace("- Saved", "- **Sessions:** Saved"), BODY.replace("fx keeps", "Fx keeps"),
                     BODY.replace("Saved conversations now resume after a restart.", "Fixed #123."),
                     BODY.split("\n\n", 1)[1], BODY + "\n### Security\n"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                notes.validate_body(body)

    def test_workflow_commit_submits_only_version_files_and_binds_the_existing_head(self):
        self.commit_notes()
        with self.checkout():
            plan = notes.make_plan(42)
            notes.apply_version(plan)
        before = self.files()
        executables = self.directory / "bin"
        executables.mkdir()
        base64_command = executables / "base64"
        base64_command.write_text(f"#!{sys.executable}\nimport base64,pathlib,sys\nprint(base64.b64encode(pathlib.Path(sys.argv[-1]).read_bytes()).decode())\n")
        base64_command.chmod(0o755)
        gh = executables / "gh"
        gh.write_text(f"#!{sys.executable}\n" +
                      "import json,os,pathlib,sys\n" +
                      "if sys.argv[1:3] == ['api','graphql']:\n" +
                      "    data=pathlib.Path(sys.argv[sys.argv.index('--input')+1]).read_text()\n" +
                      "    pathlib.Path(os.environ['FX_TEST_REQUEST']).write_text(data)\n" +
                      "    print('c'*40)\n" +
                      "elif sys.argv[1]=='api' and '/commits/' in sys.argv[2]:\n" +
                      "    print('true')\n" +
                      "else:\n" +
                      "    raise SystemExit('unexpected GitHub operation')\n")
        gh.chmod(0o755)
        environment = {**self.environment, "PATH": f"{executables}{os.pathsep}{os.environ['PATH']}",
                       "GITHUB_REPOSITORY": "vercel-labs/fx", "VERSION": plan["version"],
                       "BRANCH": plan["branch"], "EXPECTED_HEAD": plan["expected_head"],
                       "RUNNER_TEMP": str(self.directory), "GITHUB_OUTPUT": str(self.directory / "outputs"),
                       "FX_TEST_REQUEST": str(self.directory / "request.json")}
        result = subprocess.run([shutil.which("bash"), "-euo", "pipefail", "-c",
                                 workflow_script("prepare-release.yml", "Commit prepared release")],
                                cwd=self.root, env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        request = json.loads((self.directory / "request.json").read_text())["variables"]["input"]
        self.assertEqual(self.pr["headRefOid"], request["expectedHeadOid"])
        self.assertEqual(self.pr["headRefName"], request["branch"]["branchName"])
        additions = request["fileChanges"]["additions"]
        self.assertEqual({"src/main.zig", "README.md"}, {entry["path"] for entry in additions})
        for entry in additions:
            self.assertEqual(before[entry["path"]], base64.b64decode(entry["contents"]))
        self.assertEqual(before, self.files())

    def test_final_source_qualification_checks_the_local_branch_and_install_pin(self):
        self.commit_notes()
        with self.checkout():
            notes.apply_version(notes.make_plan(42))
        self.git("switch", "--quiet", self.pr["headRefName"])
        self.git("add", "src/main.zig", "README.md")
        self.git("commit", "--quiet", "-m", "Align version")
        sha = self.git("rev-parse", "HEAD")
        pr = {"head": {"repo": {"full_name": "vercel-labs/fx"}, "ref": self.pr["headRefName"], "sha": sha},
              "base": {"ref": "main"}, "state": "open", "merged": False}
        with mock.patch.object(release_preparation, "github", return_value=pr):
            self.assertEqual(pr, release_preparation.inspect_release_pr(42, sha, self.root))
        (self.root / "README.md").write_text(README.replace("0.0.9", "0.0.8"))
        self.git("add", "README.md")
        self.git("commit", "--quiet", "-m", "Change install pin")
        sha = self.git("rev-parse", "HEAD")
        pr["head"]["sha"] = sha
        with mock.patch.object(release_preparation, "github", return_value=pr), self.assertRaisesRegex(ValueError, "README"):
            release_preparation.inspect_release_pr(42, sha, self.root)


if __name__ == "__main__":
    unittest.main()
