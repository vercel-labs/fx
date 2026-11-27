from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "check-provider-versions.sh"

FAKE_CURL = """#!/bin/sh
for arg in "$@"; do url="$arg"; done
case "$url" in
  https://registry.npmjs.org/@openai/codex/latest) answer="$FAKE_CODEX" ;;
  https://x.ai/cli/stable) answer="$FAKE_GROK" ;;
  *) echo "unexpected url $url" >&2; exit 2 ;;
esac
[ "$answer" = fail ] && exit 22
printf '%s' "$answer"
"""


class CheckProviderVersionsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPT_PATH, self.root / "scripts" / SCRIPT_PATH.name)
        (self.root / "src/core/gateway").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        curl = self.bin / "curl"
        curl.write_text(FAKE_CURL)
        curl.chmod(0o755)
        self.write_pins("0.172.0", "1.0.92")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_pins(self, codex: str, grok: str) -> None:
        (self.root / "src/core/gateway/provider_versions.zig").write_text(
            f'pub const codex_client_version = "{codex}";\n'
            f'pub const grok_client_version = "{grok}";\n'
        )

    def run_check(self, codex: str, grok: str) -> subprocess.CompletedProcess[str]:
        env = dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ['PATH']}",
            FAKE_CODEX=codex,
            FAKE_GROK=grok,
        )
        return subprocess.run(
            ["bash", str(self.root / "scripts" / SCRIPT_PATH.name)],
            env=env, capture_output=True, text=True,
        )

    def test_current_pins_pass(self) -> None:
        result = self.run_check('{"version":"0.172.0"}', "1.0.92\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Codex client version 0.172.0 is current.", result.stdout)
        self.assertIn("Grok client version 1.0.92 is current.", result.stdout)

    def test_a_pin_newer_than_the_release_passes(self) -> None:
        result = self.run_check('{"version":"0.171.9"}', "1.0.92")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_a_pin_behind_the_release_fails_and_names_the_line(self) -> None:
        result = self.run_check('{"version":"0.180.0"}', "1.0.100")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('Set codex_client_version to "0.180.0"', result.stdout)
        self.assertIn('Set grok_client_version to "1.0.100"', result.stdout)

    def test_a_failed_fetch_fails(self) -> None:
        result = self.run_check("fail", "fail")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("Could not read the current Codex release", result.stdout)
        self.assertIn("Could not read the current Grok release", result.stdout)

    def test_an_unreadable_pin_fails(self) -> None:
        self.write_pins("latest", "1.0.92")
        result = self.run_check('{"version":"0.172.0"}', "1.0.92")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("Could not read codex_client_version", result.stdout)

    def test_upstream_text_reaches_the_log_short_and_printable(self) -> None:
        hostile = "1.0.92\x1b]8;;https://example.com\x07" + "x" * 200
        result = self.run_check('{"version":"0.172.0"}', hostile)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        line = next(line for line in result.stdout.splitlines() if "Grok release" in line)
        shown = line.split("got '", 1)[1].rsplit("'", 1)[0]
        self.assertNotIn("\x1b", line)
        self.assertNotIn("\x07", line)
        self.assertLessEqual(len(shown), 40)


if __name__ == "__main__":
    unittest.main()
