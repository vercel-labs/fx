from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

from scripts import fuzz_nightly
from scripts.fuzz_nightly import (
    INPUT_HEADER,
    Outcome,
    Target,
    classify,
    confirm_reproducer,
    fuzz_target,
    issue_body,
    load_targets,
    matrix_names,
    recover_inputs,
    report,
)

TARGET = Target(
    name="sse_framing",
    module="fx",
    test="provider framing fuzzes chunk-invariant event data",
    iterations=1000,
)

CLEAN_ROUND = """\
======= FUZZING REPORT =======
Step: run test fuzz
Fuzz test: "gateway.sse.test.provider framing fuzzes chunk-invariant event data" (153f9ee4d2a0f02a)
Runs: 0 -> 4113
==============================
"""

# What Zig 0.17 prints, with exit status 0, when fuzzing finds a failure.
FAILED_ROUND = (
    "error: test 'gateway.sse.test.provider framing fuzzes chunk-invariant event data' "
    "exited with code 1; input saved to '.zig-cache/f/crash'\n" + CLEAN_ROUND
)


def write_input_file(path: pathlib.Path, payload: bytes, padding: int = 64) -> None:
    header = INPUT_HEADER.pack(0x153F9EE4D2A0F02A, 0, 0, len(payload))
    path.write_bytes(header + payload + b"\x00" * padding)


class FakeRunner:
    """Answers `zig build fuzz` calls from a script of outcomes. Replays fail
    when the target's corpus folder holds the bad input."""

    def __init__(self, rounds: list[Outcome], bad_input: bytes | None = None) -> None:
        self.rounds = rounds
        self.bad_input = bad_input
        self.calls: list[list[str]] = []

    def __call__(self, command, cwd: pathlib.Path, timeout: float) -> Outcome:
        self.calls.append(list(command))
        if any(arg.startswith("--fuzz=") for arg in command):
            return self.rounds.pop(0)
        folder = cwd / "tests" / "fuzz" / "corpus" / TARGET.name
        saved = [path.read_bytes() for path in folder.iterdir()] if folder.is_dir() else []
        if self.bad_input is not None and self.bad_input in saved:
            return Outcome("error: replay failed\n", 1)
        return Outcome("", 0)


class RegistryTests(unittest.TestCase):
    def test_registry_names_are_unique_and_matrix_lists_them(self) -> None:
        targets = load_targets()

        names = matrix_names(targets)

        self.assertEqual(len(names), len(set(names)))
        self.assertIn("sse_framing", names)
        self.assertEqual(["sse_framing"], matrix_names(targets, "sse_framing"))

    def test_unknown_target_is_an_error(self) -> None:
        with self.assertRaises(fuzz_nightly.FuzzNightlyError):
            matrix_names(load_targets(), "no_such_target")

    def test_every_target_names_one_fuzz_test_its_binary_reaches(self) -> None:
        src = fuzz_nightly.REPO_ROOT / "src"
        fuzz_root = (src / "fuzz_targets.zig").read_text()
        session_manager = src / "core" / "session_manager"
        sources = {path: path.read_text() for path in src.rglob("*.zig")}
        for target in load_targets():
            with self.subTest(target=target.name):
                declaration = f'test "{target.test}" {{'
                files = [path for path, text in sources.items() if declaration in text]
                self.assertEqual(1, len(files), f"{target.name}: one file must declare {declaration!r}")
                body = sources[files[0]].split(declaration, 1)[1].split('\ntest "', 1)[0]
                self.assertIn("testing.fuzz(", body)
                in_session_manager = files[0].is_relative_to(session_manager)
                self.assertEqual(target.module == "session_manager", in_session_manager)
                if target.module == "fx":
                    self.assertIn(f'@import("{files[0].relative_to(src).as_posix()}")', fuzz_root)


class ClassifyTests(unittest.TestCase):
    def test_clean_round_is_ok(self) -> None:
        self.assertEqual("ok", classify(Outcome(CLEAN_ROUND, 0), TARGET.test))

    def test_failure_is_found_even_with_exit_status_zero(self) -> None:
        self.assertEqual("failure", classify(Outcome(FAILED_ROUND, 0), TARGET.test))

    def test_timeout_is_a_hang(self) -> None:
        self.assertEqual("hang", classify(Outcome(CLEAN_ROUND, None), TARGET.test))

    def test_nonzero_exit_without_a_test_failure_is_a_build_error(self) -> None:
        self.assertEqual("build-error", classify(Outcome("error: compile failed\n", 1), TARGET.test))

    def test_round_without_the_registered_test_is_reported(self) -> None:
        self.assertEqual("missing-test", classify(Outcome("Build Summary: 1/1\n", 0), TARGET.test))


class RecoverInputsTests(unittest.TestCase):
    def test_reads_inputs_from_fuzzer_files_when_the_saved_crash_is_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            inputs = pathlib.Path(tmp) / "f"
            inputs.mkdir()
            (inputs / "crash").write_bytes(b"")
            write_input_file(inputs / "in0", b"\x4d\x00\x00\x00bad")
            write_input_file(inputs / "in1", b"\x4d\x00\x00\x00bad")
            write_input_file(inputs / "in2", b"other")
            (inputs / "d1e77c9a9250cf56").mkdir()

            self.assertEqual([b"\x4d\x00\x00\x00bad", b"other"], recover_inputs(pathlib.Path(tmp)))

    def test_a_non_empty_saved_crash_comes_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            inputs = pathlib.Path(tmp) / "f"
            inputs.mkdir()
            (inputs / "crash").write_bytes(b"saved")
            write_input_file(inputs / "in0", b"other")

            self.assertEqual([b"saved", b"other"], recover_inputs(pathlib.Path(tmp)))


class ConfirmReproducerTests(unittest.TestCase):
    def test_returns_the_candidate_that_fails_on_replay_and_cleans_up(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            runner = FakeRunner([], bad_input=b"bad")

            found = confirm_reproducer(TARGET, root, [b"good", b"bad"], 60, runner)

            self.assertEqual(b"bad", found)
            self.assertEqual([], list(root.iterdir()))

    def test_keeps_corpus_folders_that_already_existed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            existing = root / "tests" / "fuzz" / "corpus"
            existing.mkdir(parents=True)

            confirm_reproducer(TARGET, root, [b"bad"], 60, FakeRunner([], bad_input=b"bad"))

            self.assertEqual([], list(existing.iterdir()))

    def test_no_candidate_is_blamed_when_the_replay_already_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            def always_fails(command, cwd, timeout):
                return Outcome("", 1)

            self.assertIsNone(confirm_reproducer(TARGET, pathlib.Path(tmp), [b"bad"], 60, always_fails))


class FuzzTargetTests(unittest.TestCase):
    def test_runs_rounds_until_the_budget_is_spent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            ticks = iter([0, 10, 20, 30])
            runner = FakeRunner([Outcome(CLEAN_ROUND, 0)] * 3)

            result = fuzz_target(
                TARGET, root, root / "out", budget=25, runner=runner, clock=lambda: next(ticks)
            )

            self.assertEqual("ok", result["status"])
            self.assertEqual(3, result["rounds"])
            self.assertEqual("ok", json.loads((root / "out" / "result.json").read_text())["status"])

    def test_failure_writes_the_confirmed_reproducer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            inputs = root / ".zig-cache" / "f"
            inputs.mkdir(parents=True)
            bad = b"\x4d\x00\x00\x00bad"
            replay = FakeRunner([], bad_input=bad)

            def runner(command, cwd, timeout):
                if any(arg.startswith("--fuzz=") for arg in command):
                    write_input_file(inputs / "in0", bad)
                    return Outcome(FAILED_ROUND, 0)
                return replay(command, cwd, timeout)

            result = fuzz_target(TARGET, root, root / "out", runner=runner, clock=lambda: 0)

            self.assertEqual("failure", result["status"])
            self.assertEqual(bad, (root / "out" / result["reproducer"]).read_bytes())

    def test_stale_inputs_from_earlier_runs_are_removed_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            inputs = root / ".zig-cache" / "f"
            inputs.mkdir(parents=True)
            write_input_file(inputs / "in0", b"stale")
            (inputs / "crash").write_bytes(b"stale")
            corpus = inputs / "153f9ee4d2a0f02a"
            corpus.mkdir()

            fuzz_target(
                TARGET, root, root / "out", budget=0, runner=FakeRunner([Outcome(CLEAN_ROUND, 0)]), clock=lambda: 0
            )

            self.assertEqual([corpus], list(inputs.iterdir()))


class ReportTests(unittest.TestCase):
    RESULT = {
        "target": "sse_framing",
        "test": TARGET.test,
        "status": "failure",
        "rounds": 2,
        "round_timeout_seconds": 600,
        "reproducer": "sse_framing-0123456789ab",
    }

    def test_body_explains_how_to_reproduce(self) -> None:
        body = issue_body(self.RESULT, "https://example.invalid/run/1", "abc123")

        self.assertIn("fails `provider framing", body)
        self.assertIn("tests/fuzz/corpus/sse_framing/", body)
        self.assertIn("zig build fuzz -Dfuzz-target=sse_framing", body)

    def test_comments_on_the_open_issue_with_the_same_title(self) -> None:
        calls: list[list[str]] = []

        def gh(args, stdin):
            calls.append(list(args))
            if args[:2] == ["issue", "list"]:
                return json.dumps([
                    {"number": 7, "title": "Nightly fuzz failure: sse_framing_v2"},
                    {"number": 9, "title": "Nightly fuzz failure: sse_framing"},
                ])
            return ""

        action = report(self.RESULT, repo="vercel-labs/fx", run_url="u", commit="c", gh=gh)

        self.assertEqual("commented on #9", action)
        self.assertEqual(["issue", "comment", "9"], calls[-1][:3])

    def test_opens_an_issue_when_none_is_open(self) -> None:
        calls: list[list[str]] = []

        def gh(args, stdin):
            calls.append(list(args))
            return "[]" if args[:2] == ["issue", "list"] else ""

        action = report(self.RESULT, repo="vercel-labs/fx", run_url="u", commit="c", gh=gh)

        self.assertEqual("opened an issue", action)
        self.assertIn("Nightly fuzz failure: sse_framing", calls[-1])


if __name__ == "__main__":
    unittest.main()
