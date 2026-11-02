#!/usr/bin/env python3
"""Measure interactive launch latency: keypress to first fx frame.

Each run starts fx on a fresh pseudo-terminal, answers the terminal queries a
fast emulator answers (background color, cursor position, color scheme,
device attributes), and timestamps the output. After a fixed window it sends
Ctrl+D and records exit latency plus the process's CPU time and peak RSS.

Binaries are interleaved round-robin, after unrecorded warmup launches, so
every candidate sees the same machine load. Results depend on the profile and
working directory in use: by default fx runs with the caller's environment and
HOME, which is what users feel. Pass --isolated-home for a reproducible empty
profile. Auto-upgrade is disabled, and a binary that changes on disk during
the run invalidates the results.

Usage:
  python3 benchmarks/first_frame.py                              # ./zig-out/bin/fx, 30 runs
  python3 benchmarks/first_frame.py --binary /tmp/fx-base --binary ./zig-out/bin/fx
  python3 benchmarks/first_frame.py --isolated-home --cwd /tmp --runs 50 --json out.json
"""

import argparse
import fcntl
import hashlib
import json
import math
import os
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

DEFAULT_MARKER = "Run /help"

# (pattern, reply). A None reply answers DECRQM for the captured mode.
QUERY_REPLIES = [
    (re.compile(rb"\x1b\]11;\?(?:\x1b\\|\x07)"), b"\x1b]11;rgb:1d1d/1f1f/2121\x1b\\"),
    (re.compile(rb"\x1b\]10;\?(?:\x1b\\|\x07)"), b"\x1b]10;rgb:e5e5/e5e5/e5e5\x1b\\"),
    (re.compile(rb"\x1b\[6n"), b"\x1b[1;1R"),
    (re.compile(rb"\x1b\[\?996n"), b"\x1b[?997;1n"),
    (re.compile(rb"\x1b\[\?u"), b"\x1b[?0u"),
    (re.compile(rb"\x1b\[>q"), b"\x1bP>|first-frame\x1b\\"),
    (re.compile(rb"\x1b\[\?(\d+)\$p"), None),
    (re.compile(rb"\x1b\[0?c"), b"\x1b[?62;22c"),
    (re.compile(rb"\x1b\[18t"), b"\x1b[8;50;200t"),
]


def query_replies(chunk, background_reply=True):
    """Return the bytes a responsive terminal would send back for `chunk`.

    Without `background_reply`, act like a terminal that ignores the OSC 11
    background color query but answers everything else.
    """
    out = b""
    for pattern, reply in QUERY_REPLIES if background_reply else QUERY_REPLIES[1:]:
        for match in pattern.finditer(chunk):
            out += b"\x1b[?" + match.group(1) + b";2$y" if reply is None else reply
    return out


def percentile(values, p):
    """Nearest-rank percentile; None for an empty sample."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(p / 100 * len(ordered))) - 1]


def run_once(binary, cwd, env, window_s, marker, rows, cols, background_reply=True):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def become_session_leader():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    start = time.perf_counter()
    proc = subprocess.Popen([binary], cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
                            preexec_fn=become_session_leader, close_fds=True)
    os.close(slave)
    first_byte = first_frame = eof_sent = None
    seen = b""
    status = rusage = None
    marker_bytes = marker.encode()
    while True:
        now = time.perf_counter()
        if eof_sent is None and now - start >= window_s:
            os.write(master, b"\x04")
            eof_sent = time.perf_counter()
        ready, _, _ = select.select([master], [], [], 0.02)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                stamp = time.perf_counter()
                if first_byte is None:
                    first_byte = stamp
                seen = (seen + data)[-65536:]
                reply = query_replies(data, background_reply)
                if reply:
                    os.write(master, reply)
                if first_frame is None and marker_bytes in seen:
                    first_frame = stamp
        pid, status, rusage = os.wait4(proc.pid, os.WNOHANG)
        if pid:
            exited = time.perf_counter()
            break
        if eof_sent is not None and time.perf_counter() - eof_sent > 10:
            proc.kill()
            _, status, rusage = os.wait4(proc.pid, 0)
            exited = time.perf_counter()
            status = -9
            break
    os.close(master)

    def ms(stamp):
        return None if stamp is None else round((stamp - start) * 1000, 3)

    return {
        "first_byte_ms": ms(first_byte),
        "first_frame_ms": ms(first_frame),
        "exit_after_eof_ms": None if eof_sent is None else round((exited - eof_sent) * 1000, 3),
        "cpu_ms": round((rusage.ru_utime + rusage.ru_stime) * 1000, 3),
        "max_rss_mib": round(rusage.ru_maxrss / (1024 * 1024), 2),
        "status": status,
    }


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def summarize(samples):
    def column(key):
        return [s[key] for s in samples if s[key] is not None]

    frames = column("first_frame_ms")
    return {
        "runs": len(samples),
        "missing_frame": len(samples) - len(frames),
        "failed": sum(1 for s in samples if s["status"] != 0),
        "first_byte_p50": percentile(column("first_byte_ms"), 50),
        "first_frame_p50": percentile(frames, 50),
        "first_frame_p95": percentile(frames, 95),
        "first_frame_max": max(frames) if frames else None,
        "exit_p50": percentile(column("exit_after_eof_ms"), 50),
        "cpu_p50": percentile(column("cpu_ms"), 50),
        "rss_p50": percentile(column("max_rss_mib"), 50),
    }


def print_table(names, summaries):
    def fmt(value):
        return "-" if value is None else f"{value:.1f}"

    print("| binary | runs | first byte p50 | first frame p50 | p95 | max | exit p50 | CPU p50 | RSS p50 |")
    print("|---|---|---|---|---|---|---|---|---|")
    for name in names:
        s = summaries[name]
        flags = ""
        if s["failed"] or s["missing_frame"]:
            flags = f" ({s['failed']} failed, {s['missing_frame']} without frame)"
        print(f"| {name}{flags} | {s['runs']} | {fmt(s['first_byte_p50'])} ms | {fmt(s['first_frame_p50'])} ms | "
              f"{fmt(s['first_frame_p95'])} ms | {fmt(s['first_frame_max'])} ms | {fmt(s['exit_p50'])} ms | "
              f"{fmt(s['cpu_p50'])} ms | {fmt(s['rss_p50'])} MiB |")
    if len(names) > 1:
        base = summaries[names[0]]["first_frame_p50"]
        for name in names[1:]:
            other = summaries[name]["first_frame_p50"]
            if base and other:
                delta = other - base
                direction = "faster" if delta < 0 else "slower"
                print(f"\nfirst frame p50: {name} is {abs(delta):.1f} ms {direction} than {names[0]} "
                      f"({delta / base * 100:+.1f}%)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", action="append", help="fx binary to measure (repeatable)")
    parser.add_argument("--runs", type=int, default=30, help="runs per binary")
    parser.add_argument("--warmup", type=int, default=2,
                        help="unrecorded launches per binary first; macOS scans a new binary on its first run")
    parser.add_argument("--window", type=float, default=2.0, help="seconds before Ctrl+D")
    parser.add_argument("--cwd", default=os.getcwd(), help="working directory for fx")
    parser.add_argument("--env", action="append", default=[], help="extra KEY=VALUE for fx")
    parser.add_argument("--isolated-home", action="store_true", help="run with an empty temporary HOME")
    parser.add_argument("--marker", default=DEFAULT_MARKER, help="text that marks the first frame")
    parser.add_argument("--rows", type=int, default=50)
    parser.add_argument("--cols", type=int, default=200)
    parser.add_argument("--json", help="write raw samples and summaries here")
    parser.add_argument("--no-background-reply", action="store_true",
                        help="ignore the background color query, like a terminal without OSC 11")
    args = parser.parse_args()
    background_reply = not args.no_background_reply

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    binaries = [os.path.abspath(b) for b in (args.binary or [os.path.join(repo_root, "zig-out", "bin", "fx")])]
    if len(set(binaries)) != len(binaries):
        sys.exit("error: pass each binary once")
    for binary in binaries:
        if not os.access(binary, os.X_OK):
            sys.exit(f"error: not executable: {binary}")

    env = dict(os.environ)
    env.pop("TMUX", None)
    # fx updates its own executable in place; a measured binary must not change.
    env.setdefault("FX_AUTO_UPGRADE", "0")
    env.setdefault("TERM_PROGRAM", "ghostty")
    env["TERM"] = "xterm-256color"
    temp_home = None
    if args.isolated_home:
        temp_home = tempfile.TemporaryDirectory(prefix="fx-first-frame-home-")
        env["HOME"] = temp_home.name
    for pair in args.env:
        key, sep, value = pair.partition("=")
        if not sep:
            sys.exit(f"error: --env expects KEY=VALUE, got {pair!r}")
        env[key] = value

    hashes = {binary: file_sha256(binary) for binary in binaries}
    for _ in range(args.warmup):
        for binary in binaries:
            run_once(binary, args.cwd, env, args.window, args.marker, args.rows, args.cols, background_reply)

    samples = {binary: [] for binary in binaries}
    for round_index in range(args.runs):
        for binary in binaries:
            sample = run_once(binary, args.cwd, env, args.window, args.marker, args.rows, args.cols,
                              background_reply)
            sample["round"] = round_index
            samples[binary].append(sample)
        print(f"\rround {round_index + 1}/{args.runs}", end="", file=sys.stderr, flush=True)
    print(file=sys.stderr)
    changed = [binary for binary in binaries if file_sha256(binary) != hashes[binary]]
    if changed:
        sys.exit(f"error: binary changed during the run, results discarded: {', '.join(changed)}")

    summaries = {binary: summarize(samples[binary]) for binary in binaries}
    print_table(binaries, summaries)
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"binaries": binaries, "sha256": hashes, "cwd": args.cwd, "isolated_home": args.isolated_home,
                       "background_reply": background_reply,
                       "window_s": args.window, "samples": samples, "summaries": summaries}, out, indent=2)
    if temp_home:
        temp_home.cleanup()
    if any(s["failed"] or s["missing_frame"] for s in summaries.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
