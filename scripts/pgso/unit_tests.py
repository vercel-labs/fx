"""Linux only: fx's Zig unit tests, run on code that went through the PGSO transforms.

The fx candidate's only behavior check is the E2E corpus. This step builds the
unit test executable (`zig build install-test`) through the candidate's IR
passes, outliners, and code generation, without a profile, and runs it.
Every function is marked `minsize` first, so the size-only paths, the AArch64
homogeneous prologue and epilogue, and both outliners reach as much code as
they can. The executable is relinked with Zig's own link of the control test
executable, the way scripts/pgso/linux.py relinks the fx candidate.
"""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import re

from scripts.pgso import linux
from scripts.pgso.model import PgsoError
from scripts.pgso.pipeline import (
    PROFILE_PREPARATION_PASSES,
    ArtifactSpec,
    PipelinePaths,
    _outline_without_folded_constants,
    _require_bitcode_header,
    _require_nonempty_file,
    build_control,
    candidate_object_argv,
    cleanup_outlined_ir_argv,
    emit_bitcode,
    rewrite_sparse_constants,
)
from scripts.pgso.runner import run_checked
from scripts.pgso.toolchain import Toolchain

SELECTOR = "unit_tests"
TARGETS = (linux.ARM64.TARGET, linux.X86_64.TARGET)

# The fx candidate's profile-use passes without the profile, after every
# function is marked `minsize`.
OPTIMIZE_FLAGS = (
    "-force-attribute=minsize",
    f"-passes=forceattrs,{PROFILE_PREPARATION_PASSES},default<O2>,mergefunc",
)

# These passes skip a module they cannot rewrite. The tests must run through
# them, so a skip fails the step.
REQUIRED_PASSES = ("zero-fill-globals", "compact-error-names")

# CI gives `zig build test`, compile included, 1,500 seconds.
RUN_TIMEOUT_S = 1500
# The runner prints a line per test, about 1.2 MB in all, past run_checked's
# default capture, and the retry names failures from the whole log.
RUN_CAPTURE_CHARS = 16 * 1024 * 1024

_ALL_PASSED = re.compile(r"All (\d+) tests passed\.")
_COUNTS = re.compile(r"(\d+) passed; (\d+) skipped; (\d+) failed\.")
# One line per test when stderr is not a terminal: `3/12 name...OK`. A test's
# own output can come between its name and its result.
_TEST_LINE = re.compile(r"^\d+/\d+ (.+?)\.\.\.(.*)$")


def optimize_argv(toolchain: Toolchain, paths: PipelinePaths) -> tuple[str, ...]:
    return (
        str(toolchain.opt),
        *OPTIMIZE_FLAGS,
        str(paths.bitcode),
        "-o",
        str(paths.profile_use_base_bitcode),
    )


def object_argv(toolchain: Toolchain, paths: PipelinePaths) -> tuple[str, ...]:
    """llc as for the fx candidate, with its code generation and platform flags.

    The tests are built position independent (see build.zig's `install-test`).
    llc ignores the bitcode's PIE level, and on x86_64 the default static
    model emits absolute relocations that the PIE link rejects.
    """
    argv = candidate_object_argv(toolchain, dataclasses.replace(paths, selector="fx"))
    return (*argv[:-3], "-relocation-model=pic", *argv[-3:])


def link_argv(toolchain: Toolchain, paths: PipelinePaths) -> list[str]:
    return linux.relink_argv(toolchain, paths, paths.profile_use_object, paths.candidate_binary)


def parse_test_summary(output: str) -> dict[str, int]:
    """The counts in the Zig test runner's last summary line."""
    for line in reversed(output.splitlines()):
        line = line.strip()
        if match := _ALL_PASSED.fullmatch(line):
            return {"passed": int(match[1]), "skipped": 0, "failed": 0}
        if match := _COUNTS.fullmatch(line):
            return {"passed": int(match[1]), "skipped": int(match[2]), "failed": int(match[3])}
    raise PgsoError("unit test output has no summary line")


def failed_tests(output: str) -> list[str]:
    """The tests that failed, then the one that never finished, such as a
    test that panicked and ended the run."""
    failed: list[str] = []
    running = None
    for line in output.splitlines():
        if match := _TEST_LINE.match(line):
            running = None
            result = match[2]
            if "FAIL" in result:
                failed.append(match[1])
            elif not (result.endswith("OK") or result.endswith("SKIP")):
                running = match[1]
        elif running is not None and line.startswith("FAIL"):
            failed.append(running)
            running = None
        elif running is not None and line.strip() in ("OK", "SKIP"):
            running = None
    if running is not None:
        failed.append(running)
    return failed


def require_pass_applied(paths: PipelinePaths, name: str) -> dict[str, object]:
    """The summary `ir_size.py` printed for `name`, which must not have skipped."""
    log_path = paths.logs / f"{name}.json"
    try:
        summary = json.loads(json.loads(log_path.read_text(encoding="utf-8"))["stdout"])
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise PgsoError(f"{name} left no summary in {log_path}: {error}") from error
    if not isinstance(summary, dict):
        raise PgsoError(f"{name} printed a summary that is not a JSON object in {log_path}")
    if "skipped" in summary:
        raise PgsoError(f"{name} skipped the unit tests: {summary['skipped']}")
    return summary


def build_transformed(toolchain: Toolchain, paths: PipelinePaths) -> dict[str, object]:
    """Transform `paths.bitcode` and relink it as `paths.candidate_binary`.

    The control build must already have recorded its link.
    """
    _require_nonempty_file(paths.bitcode, "unit test bitcode")
    run_checked(
        optimize_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "optimize-minsize.json",
        require_empty_stderr=True,
    )
    _require_bitcode_header(paths.profile_use_base_bitcode)
    _outline_without_folded_constants(
        toolchain, paths, paths.profile_use_base_bitcode, paths.outlined_bitcode, "unit-tests"
    )
    run_checked(
        cleanup_outlined_ir_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "cleanup-outlined-ir.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_bitcode, "outlined unit test bitcode")
    rewrite_sparse_constants(toolchain, paths)
    passes = {name: require_pass_applied(paths, name) for name in REQUIRED_PASSES}
    run_checked(
        object_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "unit-tests-object.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_object, "unit test object")
    run_checked(
        link_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-unit-tests.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.candidate_binary, "transformed unit test executable")
    return passes


def _run_once(binary: pathlib.Path, repo_root: pathlib.Path, log_path: pathlib.Path) -> dict[str, int]:
    """Run the test executable as `zig build test` does: from the repository
    root, with an open stdin pipe. The app render tests fail when stdin is
    /dev/null or at end of file."""
    result = run_checked(
        (str(binary),),
        cwd=repo_root,
        env=os.environ.copy(),
        timeout_s=RUN_TIMEOUT_S,
        log_path=log_path,
        stdin_pipe=True,
        max_capture_chars=RUN_CAPTURE_CHARS,
    )
    summary = parse_test_summary(result.stderr)
    if summary["failed"] or not summary["passed"]:
        raise PgsoError(f"unit tests did not all pass: {summary}")
    return summary


def _logged_stderr(log_path: pathlib.Path) -> str:
    try:
        return json.loads(log_path.read_text(encoding="utf-8"))["stderr"]
    except (OSError, ValueError, KeyError, TypeError):
        return ""


def run_tests(binary: pathlib.Path, repo_root: pathlib.Path, log_path: pathlib.Path) -> dict[str, object]:
    """Run the tests, and when they fail or abort, once more into a second
    log, as CI retries a failed E2E file once. A pass on the retry keeps the
    first run's failed tests in the summary and prints a warning, so a test
    that only passes on retry stays visible."""
    try:
        return {**_run_once(binary, repo_root, log_path), "retried": False}
    except PgsoError as error:
        first = {"error": str(error), "failed_tests": failed_tests(_logged_stderr(log_path)), "log": str(log_path)}
    retry_log = log_path.with_name(f"{log_path.stem}-retry{log_path.suffix}")
    try:
        summary = _run_once(binary, repo_root, retry_log)
    except PgsoError as error:
        raise PgsoError(
            f"unit tests failed twice: {first['error']}, failed {first['failed_tests']}; "
            f"retry: {error}, failed {failed_tests(_logged_stderr(retry_log))}; "
            f"logs: {log_path} and {retry_log}"
        ) from error
    print(f"::warning title=Unit tests passed only on retry::{', '.join(first['failed_tests']) or first['error']}")
    return {**summary, "retried": True, "first_attempt": first}


def transformed_unit_tests(
    toolchain: Toolchain,
    repo_root: pathlib.Path,
    output_dir: pathlib.Path,
    *,
    update_channel: str = "stable",
) -> dict[str, object]:
    if toolchain.target not in TARGETS:
        raise PgsoError(f"transformed unit tests run only on Linux, not {toolchain.target}")
    spec = ArtifactSpec(
        repo_root=repo_root,
        target=toolchain.target,
        update_channel=update_channel,
        selector=SELECTOR,
    )
    paths = PipelinePaths.create(output_dir, selector=SELECTOR)
    build_control(toolchain, spec, paths)
    emit_bitcode(toolchain, spec, paths)
    passes = build_transformed(toolchain, paths)
    tests = run_tests(paths.candidate_binary, repo_root, paths.logs / "unit-tests.json")
    return {"binary": str(paths.candidate_binary), "passes": passes, "tests": tests}
