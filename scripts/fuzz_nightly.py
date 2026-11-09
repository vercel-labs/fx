"""Nightly fuzzing driver for `.github/workflows/fuzz.yml`.

`matrix` prints the job matrix from `tests/fuzz/targets.json`.

`run` fuzzes one target in rounds of `zig build fuzz --fuzz=<iterations>`
until its time budget is spent. Zig keeps the fuzzer's corpus in
`.zig-cache/f/` between rounds, so each round continues where the last one
stopped, and a round that outlives its timeout is a hang rather than an
exhausted budget. When a round fails, `run` recovers the failing input,
confirms it by replaying it as a saved input of the target, and writes it to
the output folder with the log and `result.json`.

`report` opens the target's GitHub issue, or comments on it when one is
already open.

Two Zig 0.17 behaviors shape this script. `zig build --fuzz` exits 0 even
when it finds a failure, so a round is judged by its `error: test` line. The
input it copies to `.zig-cache/f/crash` can be empty, so the inputs are also
read from the fuzzer's `in<N>` files.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import signal
import struct
import subprocess
import sys
import time
from collections.abc import Callable, Sequence

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY_PATH = pathlib.PurePosixPath("tests/fuzz/targets.json")
CORPUS_PATH = pathlib.PurePosixPath("tests/fuzz/corpus")

# Zig 0.17 `std.Build.abi.fuzz.MmapInputHeader`, little-endian: pc_digest
# (u64), instance_id (u32), test_i (u32), len (u32). The input follows it.
INPUT_HEADER = struct.Struct("<QIII")
INPUT_FILE_NAME = re.compile(r"in[0-9a-f]+")

DEFAULT_BUDGET_SECONDS = 20 * 60
# The first round also compiles the instrumented test binary.
DEFAULT_ROUND_TIMEOUT_SECONDS = 10 * 60
DEFAULT_REPLAY_TIMEOUT_SECONDS = 10 * 60

STATUS_OK = "ok"
STATUS_FAILURE = "failure"
STATUS_HANG = "hang"
STATUS_BUILD_ERROR = "build-error"
STATUS_MISSING_TEST = "missing-test"


class FuzzNightlyError(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class Target:
    name: str
    module: str
    test: str
    iterations: int


@dataclasses.dataclass(frozen=True)
class Outcome:
    """What one `zig build` invocation printed. `returncode` is None when the
    invocation ran past its timeout and was killed."""

    output: str
    returncode: int | None


Runner = Callable[[Sequence[str], pathlib.Path, float], Outcome]


def load_targets(root: pathlib.Path = REPO_ROOT) -> list[Target]:
    data = json.loads((root / REGISTRY_PATH).read_text())
    targets = [
        Target(
            name=entry["name"],
            module=entry["module"],
            test=entry["test"],
            iterations=int(entry["iterations"]),
        )
        for entry in data["targets"]
    ]
    names = [target.name for target in targets]
    if len(set(names)) != len(names):
        raise FuzzNightlyError(f"{REGISTRY_PATH} lists a target twice")
    for target in targets:
        if target.iterations <= 0:
            raise FuzzNightlyError(f"{target.name}: iterations must be positive")
    return targets


def find_target(targets: Sequence[Target], name: str) -> Target:
    for target in targets:
        if target.name == name:
            return target
    raise FuzzNightlyError(f"unknown fuzz target {name!r}; see {REGISTRY_PATH}")


def matrix_names(targets: Sequence[Target], only: str = "") -> list[str]:
    if only:
        return [find_target(targets, only).name]
    return [target.name for target in targets]


def fuzz_command(name: str, iterations: int | None) -> list[str]:
    """`zig build fuzz` for one target. Without iterations it only replays the
    target's saved inputs."""
    command = ["zig", "build", "fuzz", "-Doptimize=ReleaseSafe", f"-Dfuzz-target={name}"]
    if iterations is not None:
        command.append(f"--fuzz={iterations}")
    return command


def run_process(command: Sequence[str], cwd: pathlib.Path, timeout: float) -> Outcome:
    """Runs `command` in its own process group, so a timeout also stops the
    fuzzer processes the build runner started."""
    process = subprocess.Popen(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
        return Outcome(output, process.returncode)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        return Outcome(output, None)


def classify(outcome: Outcome, test: str) -> str:
    if outcome.returncode is None:
        return STATUS_HANG
    lines = outcome.output.splitlines()
    if any(line.startswith("error: test '") for line in lines):
        return STATUS_FAILURE
    if outcome.returncode != 0:
        return STATUS_BUILD_ERROR
    if not any(line.startswith('Fuzz test: "') and test in line for line in lines):
        return STATUS_MISSING_TEST
    return STATUS_OK


def clear_fuzzer_inputs(cache: pathlib.Path) -> None:
    """Removes inputs left by earlier runs, keeping the fuzzer's corpus."""
    inputs = cache / "f"
    if not inputs.is_dir():
        return
    for path in inputs.iterdir():
        if path.is_file() and (path.name == "crash" or INPUT_FILE_NAME.fullmatch(path.name)):
            path.unlink()


def recover_inputs(cache: pathlib.Path) -> list[bytes]:
    """Every input the fuzzer was running when it stopped, without duplicates,
    starting with the one the build runner saved when it is not empty."""
    inputs_dir = cache / "f"
    found: list[bytes] = []
    crash = inputs_dir / "crash"
    if crash.is_file() and crash.stat().st_size > 0:
        found.append(crash.read_bytes())
    if inputs_dir.is_dir():
        for path in sorted(inputs_dir.iterdir()):
            if not path.is_file() or not INPUT_FILE_NAME.fullmatch(path.name):
                continue
            data = path.read_bytes()
            if len(data) < INPUT_HEADER.size:
                continue
            length = INPUT_HEADER.unpack_from(data)[3]
            payload = data[INPUT_HEADER.size : INPUT_HEADER.size + length]
            if len(payload) == length:
                found.append(payload)
    unique: list[bytes] = []
    for data in found:
        if data not in unique:
            unique.append(data)
    return unique


def input_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def confirm_reproducer(
    target: Target,
    root: pathlib.Path,
    candidates: Sequence[bytes],
    timeout: float,
    runner: Runner,
) -> bytes | None:
    """Replays each candidate as a saved input of the target and returns the
    first one that fails or hangs. Returns None when the target's replay
    already fails without a candidate, since no candidate can then be blamed."""
    if not candidates:
        return None
    if runner(fuzz_command(target.name, None), root, timeout).returncode != 0:
        return None
    folder = root / CORPUS_PATH / target.name
    # Deepest first, so the cleanup below can remove each one once it is empty.
    created = [path for path in (folder, *folder.parents) if path.is_relative_to(root) and not path.exists()]
    folder.mkdir(parents=True, exist_ok=True)
    try:
        for data in candidates:
            path = folder / f"nightly-{input_digest(data)}"
            path.write_bytes(data)
            try:
                outcome = runner(fuzz_command(target.name, None), root, timeout)
            finally:
                path.unlink()
            if outcome.returncode != 0:
                return data
    finally:
        for path in created:
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
    return None


def fuzz_target(
    target: Target,
    root: pathlib.Path,
    out_dir: pathlib.Path,
    *,
    budget: float = DEFAULT_BUDGET_SECONDS,
    round_timeout: float = DEFAULT_ROUND_TIMEOUT_SECONDS,
    replay_timeout: float = DEFAULT_REPLAY_TIMEOUT_SECONDS,
    runner: Runner = run_process,
    clock: Callable[[], float] = time.monotonic,
) -> dict:
    """Fuzzes `target` until the budget is spent or a round does not end
    cleanly, then writes `fuzz.log`, `result.json`, and any confirmed
    reproducer to `out_dir`. Returns the result."""
    out_dir.mkdir(parents=True, exist_ok=True)
    cache = root / ".zig-cache"
    clear_fuzzer_inputs(cache)
    deadline = clock() + budget
    log: list[str] = []
    rounds = 0
    status = STATUS_OK
    while True:
        outcome = runner(fuzz_command(target.name, target.iterations), root, round_timeout)
        rounds += 1
        status = classify(outcome, target.test)
        log.append(f"=== round {rounds}: {status} ===\n{outcome.output}")
        print(f"{target.name}: round {rounds}: {status}", flush=True)
        if status != STATUS_OK or clock() >= deadline:
            break
    (out_dir / "fuzz.log").write_text("\n".join(log))

    result: dict = {
        "target": target.name,
        "test": target.test,
        "status": status,
        "rounds": rounds,
        "round_timeout_seconds": round_timeout,
        "reproducer": None,
    }
    if status in (STATUS_FAILURE, STATUS_HANG):
        reproducer = confirm_reproducer(
            target, root, recover_inputs(cache), replay_timeout, runner
        )
        if reproducer is not None:
            name = f"{target.name}-{input_digest(reproducer)}"
            (out_dir / name).write_bytes(reproducer)
            result["reproducer"] = name
    (out_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def issue_title(name: str) -> str:
    return f"Nightly fuzz failure: {name}"


def issue_body(result: dict, run_url: str, commit: str) -> str:
    name = result["target"]
    status = result["status"]
    what = {
        STATUS_FAILURE: f"found an input that fails `{result['test']}`",
        STATUS_HANG: (
            f"found an input that hangs `{result['test']}`: a round ran past "
            f"{int(result['round_timeout_seconds'])} seconds"
        ),
        STATUS_BUILD_ERROR: "could not build or start the fuzz target",
        STATUS_MISSING_TEST: (
            f"ran no fuzz test named `{result['test']}`, so the entry in "
            f"`{REGISTRY_PATH}` no longer matches a test"
        ),
    }.get(status, "failed before it started fuzzing")
    lines = [
        f"Nightly fuzzing of `{name}` {what}.",
        "",
        f"- Run: {run_url}",
        f"- Commit: `{commit}`",
        f"- Rounds: {result['rounds']}",
    ]
    reproducer = result.get("reproducer")
    if reproducer:
        lines += [
            f"- Reproducer: `{reproducer}` in the `fuzz-{name}` artifact",
            "",
            "To reproduce:",
            "",
            f"1. Download the `fuzz-{name}` artifact from the run.",
            f"2. Copy `{reproducer}` into `{CORPUS_PATH}/{name}/`.",
            f"3. Run `zig build fuzz -Dfuzz-target={name}`. It builds in Debug, which adds allocation stack traces to leak reports.",
            "4. Fix the bug and keep the file in the fix PR, so `zig build test` replays it on every PR.",
        ]
    elif status in (STATUS_FAILURE, STATUS_HANG):
        lines += [
            "- Reproducer: none of the recovered inputs reproduced it on replay. `fuzz.log` in the artifact has the failure.",
        ]
    else:
        lines += ["", "`fuzz.log` in the artifact has the output."]
    return "\n".join(lines) + "\n"


def read_result(out_dir: pathlib.Path, target: str) -> dict:
    path = out_dir / "result.json"
    if path.is_file():
        return json.loads(path.read_text())
    return {"target": target, "test": "", "status": "setup", "rounds": 0, "reproducer": None}


GhRunner = Callable[[Sequence[str], str | None], str]


def run_gh(args: Sequence[str], stdin: str | None) -> str:
    completed = subprocess.run(
        ["gh", *args], input=stdin, text=True, capture_output=True, check=True
    )
    return completed.stdout


def report(
    result: dict,
    *,
    repo: str,
    run_url: str,
    commit: str,
    gh: GhRunner = run_gh,
) -> str:
    """Comments on the target's open issue, or opens one. Returns the action."""
    title = issue_title(result["target"])
    body = issue_body(result, run_url, commit)
    listed = gh(
        [
            "issue", "list", "--repo", repo, "--state", "open",
            "--search", f'"{title}" in:title', "--json", "number,title", "--limit", "100",
        ],
        None,
    )
    for issue in json.loads(listed or "[]"):
        if issue["title"] == title:
            gh(["issue", "comment", str(issue["number"]), "--repo", repo, "--body-file", "-"], body)
            return f"commented on #{issue['number']}"
    gh(["issue", "create", "--repo", repo, "--title", title, "--body-file", "-"], body)
    return "opened an issue"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m scripts.fuzz_nightly")
    commands = parser.add_subparsers(dest="command", required=True)

    matrix = commands.add_parser("matrix", help="print the job matrix as a GitHub output line")
    matrix.add_argument("--only", default="", help="limit the matrix to one target")

    run = commands.add_parser("run", help="fuzz one target")
    run.add_argument("--target", required=True)
    run.add_argument("--out", required=True, type=pathlib.Path)
    run.add_argument("--budget-seconds", type=float, default=DEFAULT_BUDGET_SECONDS)
    run.add_argument("--round-timeout-seconds", type=float, default=DEFAULT_ROUND_TIMEOUT_SECONDS)

    report_parser = commands.add_parser("report", help="open or update the target's issue")
    report_parser.add_argument("--target", required=True)
    report_parser.add_argument("--out", required=True, type=pathlib.Path)
    report_parser.add_argument("--repo", required=True)
    report_parser.add_argument("--run-url", required=True)
    report_parser.add_argument("--commit", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "matrix":
            names = matrix_names(load_targets(), args.only)
            print(f"targets={json.dumps(names)}")
            return 0
        if args.command == "run":
            target = find_target(load_targets(), args.target)
            result = fuzz_target(
                target,
                REPO_ROOT,
                args.out,
                budget=args.budget_seconds,
                round_timeout=args.round_timeout_seconds,
            )
            return 0 if result["status"] == STATUS_OK else 1
        result = read_result(args.out, args.target)
        print(report(result, repo=args.repo, run_url=args.run_url, commit=args.commit))
        return 0
    except FuzzNightlyError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
