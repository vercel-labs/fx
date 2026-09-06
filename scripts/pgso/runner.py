from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from collections.abc import Iterator, Mapping, Sequence
from typing import TextIO

from scripts.pgso.model import PgsoError, require_empty_stderr as ensure_empty_stderr


COMMAND_HEARTBEAT_SECONDS = 30.0
MAX_CAPTURED_OUTPUT_CHARS = 1024 * 1024
INHERITED_ENVIRONMENT_KEYS = (
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "SYSTEM_VERSION_COMPAT",
    "TEMP",
    "TERM",
    "TMP",
    "TMPDIR",
    "TZ",
    "USER",
    "__CF_USER_TEXT_ENCODING",
)


@dataclasses.dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    elapsed_seconds: float
    stdout_total_chars: int = 0
    stderr_total_chars: int = 0
    stdout_truncated: bool = False
    stderr_truncated: bool = False


class _BoundedCapture:
    def __init__(self, maximum_chars: int) -> None:
        self.maximum_chars = maximum_chars
        self.chunks: deque[str] = deque()
        self.retained_chars = 0
        self.total_chars = 0

    @property
    def truncated(self) -> bool:
        return self.total_chars > self.retained_chars

    def append(self, chunk: str) -> None:
        self.total_chars += len(chunk)
        self.chunks.append(chunk)
        self.retained_chars += len(chunk)
        while self.retained_chars > self.maximum_chars and self.chunks:
            excess = self.retained_chars - self.maximum_chars
            oldest = self.chunks[0]
            if len(oldest) <= excess:
                self.chunks.popleft()
                self.retained_chars -= len(oldest)
            else:
                self.chunks[0] = oldest[excess:]
                self.retained_chars -= excess

    def text(self) -> str:
        retained = "".join(self.chunks)
        if not self.truncated:
            return retained
        omitted = self.total_chars - self.retained_chars
        return f"[pgso truncated {omitted} earlier characters]\n{retained}"


def emit_progress(message: str) -> None:
    print(f"[pgso] {message}", flush=True)


def hermetic_environment(home: pathlib.Path) -> dict[str, str]:
    environment = {
        key: os.environ[key]
        for key in INHERITED_ENVIRONMENT_KEYS
        if key in os.environ
    }
    environment["HOME"] = str(home)
    return environment


@contextlib.contextmanager
def cancellation_guard() -> Iterator[None]:
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    handled = (signal.SIGINT, signal.SIGTERM)
    previous = {item: signal.getsignal(item) for item in handled}

    def cancel(signum, _frame) -> None:
        name = signal.Signals(signum).name
        raise PgsoError(f"pipeline cancelled by {name}")

    try:
        for item in handled:
            signal.signal(item, cancel)
        yield
    finally:
        for item, handler in previous.items():
            signal.signal(item, handler)


def _write_log(
    path: pathlib.Path,
    *,
    argv: tuple[str, ...],
    elapsed_seconds: float,
    returncode: int | None,
    stdout: str,
    stderr: str,
    status: str,
    stdout_total_chars: int | None = None,
    stderr_total_chars: int | None = None,
    stdout_truncated: bool = False,
    stderr_truncated: bool = False,
) -> None:
    payload = {
        "argv": argv,
        "command_class": pathlib.Path(argv[0]).name,
        "elapsed_seconds": elapsed_seconds,
        "returncode": returncode,
        "status": status,
        "stderr": stderr,
        "stderr_total_chars": (
            len(stderr) if stderr_total_chars is None else stderr_total_chars
        ),
        "stderr_truncated": stderr_truncated,
        "stdout": stdout,
        "stdout_total_chars": (
            len(stdout) if stdout_total_chars is None else stdout_total_chars
        ),
        "stdout_truncated": stdout_truncated,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _terminate_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def _stream_pipe(
    pipe: TextIO,
    sink: TextIO,
    capture: _BoundedCapture,
) -> None:
    try:
        while True:
            chunk = pipe.read(4096)
            if not chunk:
                return
            capture.append(chunk)
            sink.write(chunk)
            sink.flush()
    finally:
        pipe.close()


def run_checked(
    argv: Sequence[str | os.PathLike[str]],
    *,
    cwd: pathlib.Path,
    env: Mapping[str, str] | None,
    timeout_s: float,
    log_path: pathlib.Path,
    require_empty_stderr: bool = False,
) -> CommandResult:
    argv_tuple = tuple(os.fspath(argument) for argument in argv)
    if not argv_tuple:
        raise PgsoError("cannot run an empty command")
    if timeout_s <= 0:
        raise PgsoError("command timeout must be positive")

    command_display = shlex.join(argv_tuple)
    emit_progress(f"command started: {command_display} (log: {log_path})")
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            argv_tuple,
            cwd=cwd,
            env=None if env is None else dict(env),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=True,
        )
    except OSError as error:
        elapsed_seconds = time.monotonic() - started
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=None,
            stdout="",
            stderr=str(error),
            status="spawn_failed",
        )
        emit_progress(
            f"command spawn failed in {elapsed_seconds:.3f}s: "
            f"{command_display}: {error}"
        )
        if isinstance(error, FileNotFoundError):
            raise PgsoError(f"executable not found: {argv_tuple[0]}") from error
        raise PgsoError(f"could not start command: {error}") from error

    if process.stdout is None or process.stderr is None:
        _terminate_process_group(process)
        raise PgsoError("command output pipes were not created")

    stdout_capture = _BoundedCapture(MAX_CAPTURED_OUTPUT_CHARS)
    stderr_capture = _BoundedCapture(MAX_CAPTURED_OUTPUT_CHARS)
    stdout_thread = threading.Thread(
        target=_stream_pipe,
        args=(process.stdout, sys.stdout, stdout_capture),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=_stream_pipe,
        args=(process.stderr, sys.stderr, stderr_capture),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()

    # POSIX timed waits poll; observe exit before supervision and log-drain delays.
    completed = threading.Event()
    completed_at = started
    wait_error: BaseException | None = None

    def wait_for_exit() -> None:
        nonlocal completed_at, wait_error
        try:
            process.wait()
        except BaseException as error:
            wait_error = error
        finally:
            completed_at = time.monotonic()
            completed.set()

    wait_thread = threading.Thread(target=wait_for_exit, daemon=True)
    timed_out = False
    deadline = time.monotonic() + timeout_s
    next_heartbeat = time.monotonic() + COMMAND_HEARTBEAT_SECONDS
    try:
        wait_thread.start()
        while process.poll() is None:
            now = time.monotonic()
            if now >= deadline:
                timed_out = True
                _terminate_process_group(process)
                break
            wait_seconds = max(0.001, min(deadline, next_heartbeat) - now)
            if completed.wait(wait_seconds):
                break
            now = time.monotonic()
            if now >= deadline:
                timed_out = True
                _terminate_process_group(process)
                break
            if now >= next_heartbeat:
                emit_progress(
                    f"command still running after {now - started:.1f}s: "
                    f"{command_display} (log: {log_path})"
                )
                while next_heartbeat <= now:
                    next_heartbeat += COMMAND_HEARTBEAT_SECONDS
        wait_thread.join()
        if wait_error is not None:
            raise wait_error
    except BaseException:
        _terminate_process_group(process)
        if wait_thread.ident is not None:
            wait_thread.join()
        stdout_thread.join()
        stderr_thread.join()
        elapsed_seconds = time.monotonic() - started
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=process.returncode,
            stdout=stdout_capture.text(),
            stderr=stderr_capture.text(),
            status="cancelled",
            stdout_total_chars=stdout_capture.total_chars,
            stderr_total_chars=stderr_capture.total_chars,
            stdout_truncated=stdout_capture.truncated,
            stderr_truncated=stderr_capture.truncated,
        )
        emit_progress(f"command cancelled after {elapsed_seconds:.3f}s: {command_display}")
        raise

    elapsed_seconds = completed_at - started
    stdout_thread.join()
    stderr_thread.join()
    stdout = stdout_capture.text()
    stderr = stderr_capture.text()

    def write_status(status: str) -> None:
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=process.returncode,
            stdout=stdout,
            stderr=stderr,
            status=status,
            stdout_total_chars=stdout_capture.total_chars,
            stderr_total_chars=stderr_capture.total_chars,
            stdout_truncated=stdout_capture.truncated,
            stderr_truncated=stderr_capture.truncated,
        )

    if timed_out:
        write_status("timed_out")
        emit_progress(
            f"command timed out in {elapsed_seconds:.3f}s: {command_display}"
        )
        raise PgsoError(
            f"command timed out after {timeout_s:g} seconds: {argv_tuple[0]}"
        )

    result = CommandResult(
        argv=argv_tuple,
        returncode=process.returncode,
        stdout=stdout,
        stderr=stderr,
        elapsed_seconds=elapsed_seconds,
        stdout_total_chars=stdout_capture.total_chars,
        stderr_total_chars=stderr_capture.total_chars,
        stdout_truncated=stdout_capture.truncated,
        stderr_truncated=stderr_capture.truncated,
    )
    if result.returncode != 0:
        write_status("failed")
        emit_progress(
            f"command failed in {elapsed_seconds:.3f}s: {command_display} "
            f"(exit: {result.returncode})"
        )
        raise PgsoError(
            f"command failed with exit code {result.returncode}: {argv_tuple[0]}"
        )

    if require_empty_stderr and stderr:
        write_status("unexpected_stderr")
        emit_progress(
            f"command rejected stderr in {elapsed_seconds:.3f}s: {command_display}"
        )
        ensure_empty_stderr("command", stderr)

    write_status("passed")
    emit_progress(f"command passed in {elapsed_seconds:.3f}s: {command_display}")
    return result
