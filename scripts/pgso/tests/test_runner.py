from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import shlex
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from scripts.pgso.model import PgsoError
from scripts.pgso.runner import cancellation_guard, run_checked


class PgsoRunnerTests(unittest.TestCase):
    def test_elapsed_stops_at_process_exit_before_output_drains(self) -> None:
        from scripts.pgso import runner

        exited = threading.Event()
        completion_observed = threading.Event()
        release_output = threading.Event()
        process = mock.Mock()
        process.stdout = io.StringIO("child output\n")
        process.stderr = io.StringIO("")
        process.returncode = None
        process.poll.side_effect = lambda: process.returncode
        waiter_ident: int | None = None

        def wait(*args, **kwargs):
            nonlocal waiter_ident
            waiter_ident = threading.get_ident()
            process.returncode = 0
            exited.set()
            return 0

        def clock() -> float:
            if release_output.is_set():
                return 10.0
            if exited.is_set() and threading.get_ident() == waiter_ident:
                completion_observed.set()
                return 2.0
            return 1.0

        stream_pipe = runner._stream_pipe

        def delayed_output(*args):
            release_output.wait()
            stream_pipe(*args)

        process.wait.side_effect = wait
        results: list[runner.CommandResult] = []
        errors: list[BaseException] = []
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)

            def invoke() -> None:
                try:
                    results.append(
                        run_checked(
                            ["fixture"],
                            cwd=root,
                            env={},
                            timeout_s=20,
                            log_path=root / "timing.json",
                        )
                    )
                except BaseException as error:
                    errors.append(error)

            with (
                mock.patch("scripts.pgso.runner.subprocess.Popen", return_value=process),
                mock.patch("scripts.pgso.runner.time.monotonic", side_effect=clock),
                mock.patch("scripts.pgso.runner._stream_pipe", side_effect=delayed_output),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                worker = threading.Thread(target=invoke, daemon=True)
                worker.start()
                try:
                    observed_before_drain = completion_observed.wait(timeout=0.5)
                finally:
                    release_output.set()
                    worker.join(timeout=2)

            self.assertFalse(worker.is_alive())
            self.assertEqual([], errors)
            self.assertTrue(observed_before_drain)
            self.assertEqual(1.0, results[0].elapsed_seconds)
            self.assertEqual("child output\n", results[0].stdout)
            log = json.loads((root / "timing.json").read_text())
            self.assertEqual(results[0].elapsed_seconds, log["elapsed_seconds"])

    def test_cancellation_guard_converts_sigterm_and_restores_handlers(self) -> None:
        installed: dict[object, object] = {}

        def install(signum, handler):
            installed[signum] = handler

        with (
            mock.patch("scripts.pgso.runner.signal.getsignal", return_value="original"),
            mock.patch("scripts.pgso.runner.signal.signal", side_effect=install),
        ):
            with self.assertRaisesRegex(PgsoError, "cancelled by SIGTERM"):
                with cancellation_guard():
                    handler = installed[signal.SIGTERM]
                    assert callable(handler)
                    handler(signal.SIGTERM, None)

        self.assertEqual("original", installed[signal.SIGINT])
        self.assertEqual("original", installed[signal.SIGTERM])

    def test_child_output_is_visible_before_the_command_finishes(self) -> None:
        class LiveOutput(io.StringIO):
            def __init__(self) -> None:
                super().__init__()
                self.marker_seen = threading.Event()

            def write(self, value: str) -> int:
                written = super().write(value)
                if "early output" in value:
                    self.marker_seen.set()
                return written

        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = LiveOutput()
            errors: list[Exception] = []

            def invoke() -> None:
                try:
                    run_checked(
                        [
                            sys.executable,
                            "-c",
                            (
                                "import time; "
                                "print('early output', flush=True); "
                                "time.sleep(1)"
                            ),
                        ],
                        cwd=root,
                        env=os.environ.copy(),
                        timeout_s=5,
                        log_path=root / "live-before-exit.json",
                    )
                except Exception as error:
                    errors.append(error)

            with contextlib.redirect_stdout(stdout):
                worker = threading.Thread(target=invoke, daemon=True)
                worker.start()
                observed_while_running = stdout.marker_seen.wait(timeout=0.5)
                command_still_running = worker.is_alive()
                worker.join(timeout=3)

            self.assertTrue(observed_while_running)
            self.assertTrue(command_still_running)
            self.assertFalse(worker.is_alive())
            self.assertEqual([], errors)

    def test_silent_command_emits_periodic_heartbeats(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()

            with (
                contextlib.redirect_stdout(stdout),
                mock.patch(
                    "scripts.pgso.runner.COMMAND_HEARTBEAT_SECONDS",
                    0.05,
                    create=True,
                ),
            ):
                run_checked(
                    [sys.executable, "-c", "import time; time.sleep(0.2)"],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "heartbeat.json",
                )

            output = stdout.getvalue()
            self.assertRegex(
                output,
                r"\[pgso\] command still running after \d+\.\d+s",
            )
            self.assertIn("heartbeat.json", output)

    def test_success_streams_command_lifecycle_and_child_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()
            stderr = io.StringIO()

            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import sys; "
                            "print('live stdout', flush=True); "
                            "print('live stderr', file=sys.stderr, flush=True)"
                        ),
                    ],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "live.json",
                )

            output = stdout.getvalue()
            self.assertIn("[pgso] command started", output)
            self.assertIn("live stdout\n", output)
            self.assertRegex(output, r"\[pgso\] command passed in \d+\.\d{3}s")
            self.assertLess(output.index("command started"), output.index("live stdout"))
            self.assertLess(output.index("live stdout"), output.index("command passed"))
            self.assertIn("live stderr\n", stderr.getvalue())

    def test_failure_streams_terminal_status_after_child_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()

            with (
                contextlib.redirect_stdout(stdout),
                self.assertRaisesRegex(PgsoError, "command failed with exit code 7"),
            ):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "print('failure detail', flush=True); raise SystemExit(7)",
                    ],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "failure.json",
                )

            output = stdout.getvalue()
            self.assertIn("failure detail\n", output)
            self.assertRegex(output, r"\[pgso\] command failed in \d+\.\d{3}s")
            self.assertLess(output.index("failure detail"), output.index("command failed"))

    def test_success_captures_output_and_writes_a_bounded_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"
            env = os.environ.copy()
            env["PGSO_TEST_SECRET"] = "must-not-be-logged"

            result = run_checked(
                [
                    sys.executable,
                    "-c",
                    "import sys; print('stdout'); print('stderr', file=sys.stderr)",
                ],
                cwd=pathlib.Path(tmp),
                env=env,
                timeout_s=5,
                log_path=log_path,
            )

            self.assertEqual(0, result.returncode)
            self.assertEqual("stdout\n", result.stdout)
            self.assertEqual("stderr\n", result.stderr)
            self.assertGreaterEqual(result.elapsed_seconds, 0)
            log = json.loads(log_path.read_text())
            self.assertEqual(pathlib.Path(sys.executable).name, log["command_class"])
            self.assertEqual("passed", log["status"])
            self.assertNotIn("environment", log)
            self.assertNotIn("must-not-be-logged", log_path.read_text())

    def test_noisy_output_is_truncated_in_memory_and_in_the_json_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            log_path = root / "bounded.json"
            with (
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()),
                mock.patch(
                    "scripts.pgso.runner.MAX_CAPTURED_OUTPUT_CHARS",
                    128,
                ),
            ):
                result = run_checked(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('x' * 4096); print('y' * 4096, file=sys.stderr)",
                    ],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                )

            log = json.loads(log_path.read_text())
            self.assertTrue(result.stdout_truncated)
            self.assertTrue(result.stderr_truncated)
            self.assertTrue(log["stdout_truncated"])
            self.assertTrue(log["stderr_truncated"])
            self.assertGreater(log["stdout_total_chars"], 4096)
            self.assertGreater(log["stderr_total_chars"], 4096)
            self.assertLess(len(log["stdout"]), 256)
            self.assertLess(len(log["stderr"]), 256)

    def test_interruption_terminates_the_process_group_and_logs_cancellation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            process = mock.Mock()
            process.stdout = io.StringIO("partial stdout\n")
            process.stderr = io.StringIO("")
            process.poll.return_value = None
            process.wait.side_effect = KeyboardInterrupt()
            process.returncode = -2
            log_path = root / "cancelled.json"

            with (
                mock.patch("scripts.pgso.runner.subprocess.Popen", return_value=process),
                mock.patch("scripts.pgso.runner._terminate_process_group") as terminate,
                self.assertRaises(KeyboardInterrupt),
            ):
                run_checked(
                    ["fixture"],
                    cwd=root,
                    env={},
                    timeout_s=5,
                    log_path=log_path,
                )

            terminate.assert_called_once_with(process)
            log = json.loads(log_path.read_text())
            self.assertEqual("cancelled", log["status"])
            self.assertEqual("partial stdout\n", log["stdout"])

    def test_nonzero_exit_raises_after_logging_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(
                PgsoError,
                "command failed with exit code 7",
            ):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('before failure'); sys.exit(7)",
                    ],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual(7, log["returncode"])
            self.assertEqual("before failure\n", log["stdout"])
            self.assertEqual("failed", log["status"])

    def test_empty_stderr_policy_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(PgsoError, "wrote unexpected stderr"):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('optimizer warning', file=sys.stderr)",
                    ],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                    require_empty_stderr=True,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual("unexpected_stderr", log["status"])
            self.assertEqual("optimizer warning\n", log["stderr"])

    def test_missing_executable_fails_closed_and_writes_a_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(PgsoError, "executable not found"):
                run_checked(
                    [str(pathlib.Path(tmp) / "missing-command")],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual("spawn_failed", log["status"])
            self.assertIsNone(log["returncode"])

    def test_timeout_terminates_the_whole_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            marker = root / "child-survived"
            log_path = root / "stage.json"
            script = root / "timeout-fixture.sh"
            script.write_text(
                "#!/bin/sh\n"
                f"(sleep 1; printf survived > {shlex.quote(str(marker))}) &\n"
                "printf 'started\\n'\n"
                "sleep 30\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(PgsoError, "timed out after 0.5 seconds"):
                run_checked(
                    ["/bin/sh", str(script)],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=0.5,
                    log_path=log_path,
                )

            time.sleep(1.2)
            self.assertFalse(marker.exists())
            log = json.loads(log_path.read_text())
            self.assertEqual("timed_out", log["status"])
            self.assertIn("started\n", log["stdout"])


if __name__ == "__main__":
    unittest.main()
