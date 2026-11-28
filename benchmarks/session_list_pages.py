#!/usr/bin/env python3
"""Time one full ACP session/list listing, every page, for one or more fx binaries.

The script builds a made-up profile: --v2 sessions that the first binary converts to v2, then --v1 sessions that stay v1. For each round it runs `fx acp` for each binary in turn, sends initialize and then session/list with each nextCursor until none is left, and times only the listing. CPU time (user and system) is the whole child process, read with wait4 after its stdin closes, so it includes startup and initialize. The made-up profile has no `.resume-catalog`, so every v1 read classifies each folder in full. A listing that changes the folder counts fails the run.

Usage:
  python3 benchmarks/session_list_pages.py --binary /path/to/base/fx --binary /path/to/head/fx
  python3 benchmarks/session_list_pages.py --binary ./zig-out/bin/fx --rounds 5 --json samples.json
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "v1-sessions" / "plain" / "sessions" / "cb1PK0RGxCmY"
COPIED_FIXTURE_FILES = ("events.jsonl", "permissions.json")
V2_DIR_NAME = "v2"
WORK_DIR_PREFIX = "fx-session-list-pages-"

DEFAULT_V1_SESSIONS = 16_000
DEFAULT_V2_SESSIONS = 3_000
DEFAULT_ROUNDS = 3
MAX_PAGES = 10_000
SESSION_ID_PREFIX = "b"
SESSION_ID_DIGITS = 11
FIRST_CREATED_AT_MS = 1792257545742
SESSION_STEP_MS = 1_000
NS_PER_MS = 1_000_000
PRIVATE_DIR_MODE = 0o700
PRIVATE_FILE_MODE = 0o600
INITIALIZE_ID = 1
FIRST_LIST_ID = 2
# No model call happens in a listing, so this placeholder never reaches a provider; never a real key.
NO_MODEL_API_KEY = "fx-benchmark-no-model-calls"
# A closed loopback port: a stray request fails here and cannot leave the machine.
NO_MODEL_GATEWAY_URL = "http://127.0.0.1:9"
INITIALIZE_PARAMS = {
    "protocolVersion": 1,
    "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
}


class BenchmarkError(Exception):
    """A failure that stops the run and is printed to stderr."""


def count_at_least(minimum: int):
    def parse(text: str) -> int:
        value = int(text)
        if value < minimum:
            raise argparse.ArgumentTypeError(f"must be at least {minimum}")
        return value

    return parse


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", action="append", required=True, metavar="PATH",
                        help="fx binary to time; repeat for each one. The first one converts the profile.")
    parser.add_argument("--v1", type=count_at_least(0), default=DEFAULT_V1_SESSIONS, metavar="N",
                        help="v1 sessions to make (default: %(default)s)")
    parser.add_argument("--v2", type=count_at_least(0), default=DEFAULT_V2_SESSIONS, metavar="N",
                        help="sessions to convert to v2 (default: %(default)s)")
    parser.add_argument("--rounds", type=count_at_least(1), default=DEFAULT_ROUNDS, metavar="N",
                        help="interleaved rounds over all binaries (default: %(default)s)")
    parser.add_argument("--work", metavar="DIR",
                        help="work dir, which must be empty or missing (default: a new temporary directory)")
    parser.add_argument("--json", metavar="PATH", help="write every raw sample here as JSON")
    parser.add_argument("--keep", action="store_true",
                        help="keep the work dir even when this script made it")
    return parser


def resolve_binaries(parser: argparse.ArgumentParser, paths: list[str]) -> list[str]:
    binaries = [os.path.abspath(path) for path in paths]
    if len(set(binaries)) != len(binaries):
        parser.error("pass each --binary once")
    for binary in binaries:
        if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
            parser.error(f"not an executable file: {binary}")
    return binaries


def prepare_work_dir(requested: str | None) -> tuple[Path, bool]:
    if requested is None:
        return Path(tempfile.mkdtemp(prefix=WORK_DIR_PREFIX)), True
    work = Path(os.path.abspath(requested))
    made = not work.exists()
    if not made and (not work.is_dir() or any(work.iterdir())):
        raise BenchmarkError(f"work dir must be empty or missing: {work}")
    work.mkdir(parents=True, exist_ok=True)
    return work, made


def make_private_dir(path: Path) -> None:
    path.mkdir(mode=PRIVATE_DIR_MODE)
    path.chmod(PRIVATE_DIR_MODE)


def write_private_file(path: Path, data: bytes) -> None:
    path.write_bytes(data)
    path.chmod(PRIVATE_FILE_MODE)


def session_id_for(index: int) -> str:
    return f"{SESSION_ID_PREFIX}{index:0{SESSION_ID_DIGITS}d}"


def write_session(sessions_root: Path, index: int) -> None:
    session_id = session_id_for(index)
    stamp_ms = FIRST_CREATED_AT_MS + index * SESSION_STEP_MS
    folder = sessions_root / session_id
    make_private_dir(folder)
    record = json.loads((FIXTURE_DIR / "session.json").read_bytes())
    record["id"] = session_id
    record["created_at_ms"] = stamp_ms
    record["updated_at_ms"] = stamp_ms
    write_private_file(folder / "session.json", (json.dumps(record, separators=(",", ":")) + "\n").encode())
    for name in COPIED_FIXTURE_FILES:
        write_private_file(folder / name, (FIXTURE_DIR / name).read_bytes())
    write_private_file(folder / "session.lock", b"")
    # Gives events.jsonl the session's update time, so the copy's mtime matches its record.
    stamp_ns = stamp_ms * NS_PER_MS
    os.utime(folder / "events.jsonl", ns=(stamp_ns, stamp_ns))


def is_v1_folder(entry: Path) -> bool:
    name = entry.name
    return entry.is_dir() and name != V2_DIR_NAME and "+" not in name and not name.startswith(".")


def count_v1_folders(sessions_root: Path) -> int:
    return sum(1 for entry in sessions_root.iterdir() if is_v1_folder(entry))


def count_v2_folders(sessions_root: Path) -> int:
    v2_root = sessions_root / V2_DIR_NAME
    if not v2_root.is_dir():
        return 0
    return sum(1 for entry in v2_root.iterdir() if entry.is_dir() and not entry.name.startswith("."))


def count_profile(sessions_root: Path) -> tuple[int, int]:
    return count_v1_folders(sessions_root), count_v2_folders(sessions_root)


def fx_env(home: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["FX_SOUND"] = "0"
    env["FX_AUTO_UPGRADE"] = "0"
    env["AI_GATEWAY_API_KEY"] = NO_MODEL_API_KEY
    env["FX_GATEWAY_BASE_URL"] = NO_MODEL_GATEWAY_URL
    env.pop("FX_HOME", None)
    return env


def build_profile(first_binary: str, work: Path, home: Path, env: dict[str, str],
                  v1_count: int, v2_count: int) -> None:
    sessions_root = home / ".fx" / "sessions"
    home.mkdir()
    make_private_dir(home / ".fx")
    make_private_dir(sessions_root)
    for index in range(v2_count):
        write_session(sessions_root, index)
    subprocess.run([first_binary, "sessions", "convert", "--json"], cwd=work, env=env,
                   capture_output=True, check=True)
    for index in range(v2_count, v2_count + v1_count):
        write_session(sessions_root, index)
    counts = count_profile(sessions_root)
    if counts != (v1_count, v2_count):
        raise BenchmarkError(f"profile has {counts[0]} v1 and {counts[1]} v2 folders, "
                             f"expected {v1_count} and {v2_count}")
    print(f"profile: {counts[0]} v1 folders, {counts[1]} v2 folders", file=sys.stderr)


def request(proc: subprocess.Popen, request_id: int, method: str, params: dict) -> dict:
    message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    proc.stdin.write((json.dumps(message) + "\n").encode())
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise BenchmarkError(f"fx acp closed its output before replying to {method}")
        try:
            reply = json.loads(line)
        except ValueError as error:
            raise BenchmarkError(f"fx acp wrote a line that is not JSON: {line[:200]!r}") from error
        if not isinstance(reply, dict):
            continue
        # A reply with a null id can only answer a request the server could not read.
        if "error" in reply and reply.get("id") in (request_id, None):
            raise BenchmarkError(f"{method} returned an error: {json.dumps(reply['error'])}")
        if reply.get("id") == request_id:
            if "result" not in reply:
                raise BenchmarkError(f"{method} reply has no result")
            return reply


def list_every_page(proc: subprocess.Popen) -> tuple[int, int]:
    pages = 0
    sessions = 0
    cursor = None
    while True:
        if pages == MAX_PAGES:
            raise BenchmarkError(f"session/list still had a nextCursor after {MAX_PAGES} pages")
        reply = request(proc, FIRST_LIST_ID + pages, "session/list", {"cursor": cursor})
        result = reply["result"]
        pages += 1
        sessions += len(result.get("sessions", []))
        cursor = result.get("nextCursor")
        if not cursor:
            return pages, sessions


def time_listing(binary: str, work: Path, env: dict[str, str], log_path: Path) -> dict:
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "acp"], cwd=work, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    try:
        request(proc, INITIALIZE_ID, "initialize", INITIALIZE_PARAMS)
        started = time.perf_counter()
        pages, sessions = list_every_page(proc)
        wall_s = time.perf_counter() - started
        proc.stdin.close()
        # wait4 instead of Popen.wait, so the child's own rusage comes back.
        _, status, usage = os.wait4(proc.pid, 0)
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    proc.stdout.close()
    proc.returncode = os.waitstatus_to_exitcode(status)
    if proc.returncode != 0:
        raise BenchmarkError(f"{binary} acp exited with status {proc.returncode}; stderr in {log_path}")
    return {
        "pages": pages,
        "sessions": sessions,
        "wall_s": wall_s,
        "cpu_user_s": usage.ru_utime,
        "cpu_sys_s": usage.ru_stime,
    }


def cpu_seconds(sample: dict) -> float:
    return sample["cpu_user_s"] + sample["cpu_sys_s"]


def run_benchmark(args: argparse.Namespace, binaries: list[str], work: Path) -> list[dict]:
    home = work / "home"
    sessions_root = home / ".fx" / "sessions"
    env = fx_env(home)
    build_profile(binaries[0], work, home, env, args.v1, args.v2)
    samples = []
    for round_number in range(1, args.rounds + 1):
        order = list(enumerate(binaries))
        # Reverse on odd 0-based rounds, so the same binary never always runs first.
        if (round_number - 1) % 2 == 1:
            order.reverse()
        for index, binary in order:
            before = count_profile(sessions_root)
            log_path = work / f"acp-binary{index + 1}-round{round_number}.stderr.log"
            timing = time_listing(binary, work, env, log_path)
            after = count_profile(sessions_root)
            if after != before:
                raise BenchmarkError(f"listing changed the v1/v2 folder counts from {before} to {after}")
            sample = {"binary": binary, "round": round_number, **timing}
            samples.append(sample)
            print(f"round {round_number} {binary}: pages={timing['pages']} sessions={timing['sessions']} "
                  f"wall={timing['wall_s']:.3f}s cpu={cpu_seconds(sample):.3f}s", file=sys.stderr)
    return samples


def span(values: list[int]) -> str:
    low, high = min(values), max(values)
    return str(low) if low == high else f"{low}-{high}"


def print_table(binaries: list[str], samples: list[dict]) -> None:
    print("| binary | rounds | pages | sessions | wall min (s) | wall median (s) | wall max (s) "
          "| CPU min (s) | CPU median (s) | CPU max (s) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for binary in binaries:
        rows = [s for s in samples if s["binary"] == binary]
        wall = [s["wall_s"] for s in rows]
        cpu = [cpu_seconds(s) for s in rows]
        print(f"| {binary} | {len(rows)} | {span([s['pages'] for s in rows])} "
              f"| {span([s['sessions'] for s in rows])} "
              f"| {min(wall):.3f} | {statistics.median(wall):.3f} | {max(wall):.3f} "
              f"| {min(cpu):.3f} | {statistics.median(cpu):.3f} | {max(cpu):.3f} |")
    print("\nCPU is the whole fx acp process (user + sys), startup and initialize included. "
          "Wall covers only the listing.")


def print_raw(samples: list[dict]) -> None:
    print("\nraw samples")
    for sample in samples:
        print(f"binary={sample['binary']} round={sample['round']} pages={sample['pages']} "
              f"sessions={sample['sessions']} wall_s={sample['wall_s']:.6f} "
              f"cpu_user_s={sample['cpu_user_s']:.6f} cpu_sys_s={sample['cpu_sys_s']:.6f}")


def write_json(path: str, args: argparse.Namespace, binaries: list[str], samples: list[dict]) -> None:
    report = {
        "binaries": binaries,
        "v1_sessions": args.v1,
        "v2_sessions": args.v2,
        "rounds": args.rounds,
        "samples": samples,
    }
    Path(path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def failure_text(error: Exception) -> str:
    if isinstance(error, subprocess.CalledProcessError):
        detail = (error.stderr or b"").decode(errors="replace").strip()
        command = " ".join(str(part) for part in error.cmd)
        return f"{command} exited {error.returncode}: {detail}"
    return str(error)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    binaries = resolve_binaries(parser, args.binary)
    try:
        work, made_work = prepare_work_dir(args.work)
    except BenchmarkError as error:
        sys.exit(f"error: {error}")
    print(f"work dir: {work}", file=sys.stderr)
    try:
        samples = run_benchmark(args, binaries, work)
    except (BenchmarkError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {failure_text(error)}", file=sys.stderr)
        print(f"work dir kept for inspection: {work}", file=sys.stderr)
        sys.exit(1)
    print_table(binaries, samples)
    print_raw(samples)
    if args.json:
        write_json(args.json, args, binaries, samples)
    if made_work and not args.keep:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
