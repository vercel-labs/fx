from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "dev-channel-forward.sh"
UNKNOWN = "0123456789abcdef0123456789abcdef01234567"


class DevChannelForwardTests(unittest.TestCase):
    """main: base -> older -> newer -> head. side: base -> side, never merged."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": self.temp.name,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        self.git("init", "-q", "-b", "main")
        base = self.commit("base")
        self.older = self.commit("older")
        self.newer = self.commit("newer")
        self.head = self.commit("head")
        self.git("checkout", "-q", "-b", "side", base)
        self.side = self.commit("side")
        self.git("checkout", "-q", "main")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, check=True,
            capture_output=True, text=True,
        )
        return result.stdout.strip()

    def commit(self, message: str) -> str:
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def decide(self, channel: str, build: str, main: str) -> tuple[int, str, str]:
        output_path = self.root.parent / f"{self.root.name}-output"
        output_path.write_text("", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), channel, build, main],
            cwd=self.root,
            env={**self.env, "GITHUB_OUTPUT": str(output_path)},
            capture_output=True,
            text=True,
        )
        output = output_path.read_text(encoding="utf-8")
        output_path.unlink()
        return result.returncode, output, result.stdout + result.stderr

    def assert_move(self, move: bool, channel: str, build: str, main: str, says: str) -> None:
        code, output, text = self.decide(channel, build, main)
        self.assertEqual(0, code, text)
        self.assertEqual(f"move={str(move).lower()}\n", output, text)
        self.assertIn(says, text)

    def test_a_newer_build_moves_the_channel_after_main_moved_on(self) -> None:
        self.assert_move(True, self.older, self.newer, self.head, "moving it to")

    def test_an_older_build_leaves_the_channel(self) -> None:
        self.assert_move(False, self.newer, self.older, self.head, "already includes")

    def test_a_rerun_for_the_channel_commit_writes_it_again(self) -> None:
        self.assert_move(True, self.newer, self.newer, self.head, "moving it to")

    def test_an_unread_channel_moves_only_for_main_head(self) -> None:
        self.assert_move(False, "", self.newer, self.head, "could not be read")
        self.assert_move(True, "", self.head, self.head, "main's newest commit")

    def test_an_unknown_channel_commit_moves_only_for_main_head(self) -> None:
        self.assert_move(False, UNKNOWN, self.newer, self.head, "is not in the history")
        self.assert_move(True, UNKNOWN, self.head, self.head, "main's newest commit")

    def test_a_channel_commit_outside_main_moves_only_for_main_head(self) -> None:
        self.assert_move(False, self.side, self.newer, self.head, "is not in the history")
        self.assert_move(True, self.side, self.head, self.head, "main's newest commit")

    def test_a_fallback_skip_is_a_warning(self) -> None:
        self.assert_move(False, UNKNOWN, self.newer, self.head, "::warning::")

    def test_an_unread_main_matters_only_when_the_rule_needs_it(self) -> None:
        self.assert_move(True, self.older, self.newer, "", "moving it to")
        self.assert_move(False, self.newer, self.older, "", "already includes")
        code, output, text = self.decide(UNKNOWN, self.newer, "")
        self.assertEqual(1, code, text)
        self.assertEqual("", output)
        self.assertIn("could not be read", text)

    def test_without_github_output_it_still_prints_the_decision(self) -> None:
        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), self.older, self.newer, self.head],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("moving it to", result.stdout)

    def test_a_wrong_argument_count_is_a_usage_error(self) -> None:
        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), self.older, self.newer],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
