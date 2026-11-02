#!/usr/bin/env python3
"""Checks fx's `wiring` trace lines against Wiring.tla (WiringTrace.tla).

usage: check_wiring_traces.py FILE...   trace logs written with FX_TRACE=1,
                                        FX_TRACE_SCOPES=wiring, FX_TRACE_LOG
       check_wiring_traces.py --selftest

JOBS=N runs N TLC checks at once (default 6).

The adapter writes one line per step (`action=... session=... pid=...`).
Each process's first store open and last close become Start and Exit; a
process whose lines stop without Exit gets a Crash. Wiring.tla models one fx
process at a time, so a file whose processes overlap is skipped and named.
Exit 0 when every checked trace is accepted.
"""
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_saved_logs import HERE, TLA, run_tlc, tla_str  # noqa: E402

LINE = re.compile(r"^\d+ \[wiring\] action=(\w+) session=(\S+)(?: end=(\w+))? pid=(-?\d+)$")


class Skip(Exception):
    pass


def parse(path):
    events = []
    for raw in open(path, errors="replace"):
        m = LINE.match(raw.rstrip("\n"))
        if m:
            events.append((int(m.group(4)), m.group(1), m.group(2), m.group(3)))
    return events


def steps_for(events):
    """The Wiring steps, and the sessions they name."""
    order, seen = [], set()
    for pid, *_ in events:
        if pid in seen and order[-1] != pid:
            raise Skip("processes overlap")
        if pid not in seen:
            seen.add(pid)
            order.append(pid)
    names, steps = {}, []
    for pid in order:
        depth = 0
        mine = [e for e in events if e[0] == pid]
        # ACP opens its store before tracing starts: its first line is
        # then a later step, and the process started just before it.
        if mine[0][1] != "StoreOpen":
            steps.append(("Start", "none", "none"))
            depth = 1
        for p, action, session, end in mine:
            if action == "StoreOpen":
                if depth == 0:
                    steps.append(("Start", "none", "none"))
                depth += 1
            elif action == "StoreClose":
                depth -= 1
                if depth == 0:
                    steps.append(("Exit", "none", "none"))
            elif depth == 0:
                raise Skip(f"{action} outside an open store")
            elif action in ("Open", "Close", "Fork"):
                steps.append((action, names.setdefault(session, f"s{len(names) + 1}"), "none"))
            elif action == "EndTurn":
                steps.append(("EndTurn", "none", end))
            else:
                steps.append((action, "none", "none"))
        if depth > 0:
            steps.append(("Crash", "none", "none"))
    return steps, sorted(names.values()) or ["s1"]


def check(steps, sessions):
    body = ", ".join(f"[a |-> {tla_str(a)}, s |-> {tla_str(s)}, e |-> {tla_str(e)}]" for a, s, e in steps)
    data = f"---- MODULE WiringData ----\nTrace == <<{body}>>\n====\n"
    cfg = ("CONSTANT Sessions = {" + ", ".join(tla_str(s) for s in sessions) + "}\n"
           "SPECIFICATION TraceSpec\nINVARIANT NotDone\nCONSTRAINT Progress\n")
    specs = [os.path.join(TLA, "Wiring.tla"), os.path.join(HERE, "WiringTrace.tla")]
    verdict, detail = run_tlc("WiringTrace", specs, {"WiringData.tla": data}, cfg, invariant="NotDone")
    return verdict, detail


def run(path):
    events = parse(path)
    if not events:
        return path, "EMPTY", "no wiring lines"
    try:
        steps, sessions = steps_for(events)
    except Skip as why:
        return path, "SKIPPED", str(why)
    verdict, detail = check(steps, sessions)
    if verdict == "REJECTED":
        step = steps[detail] if detail < len(steps) else None
        return path, verdict, f"steps 1..{detail} match; step {detail + 1} {step} is not allowed ({len(steps)} steps)"
    return path, verdict, f"{detail}/{len(steps)} steps" if verdict == "ACCEPTED" else detail


def selftest():
    S, O, B, C, X = ("Start", "none", "none"), ("Open", "s1", "none"), ("BeginTurn", "none", "none"), ("Close", "s1", "none"), ("Exit", "none", "none")
    O2, C2 = ("Open", "s2", "none"), ("Close", "s2", "none")
    commit, crash = ("EndTurn", "none", "commit"), ("Crash", "none", "none")
    spawn, done = ("Spawn", "none", "none"), ("ChildDone", "none", "none")
    cases = [
        ("a turn, then close and exit", [S, O, B, commit, C, X], ["s1"], "ACCEPTED"),
        ("a crash mid-turn, then a resume", [S, O, B, crash, S, O, B, commit, C, X], ["s1"], "ACCEPTED"),
        ("a child inside a turn", [S, O, B, spawn, done, commit, C, X], ["s1"], "ACCEPTED"),
        ("planted: close while a child runs", [S, O, B, spawn, C], ["s1"], "REJECTED"),
        ("a switch: the next session opens before the current closes (D41)", [S, O, B, commit, O2, C, B, commit, C2, X], ["s1", "s2"], "ACCEPTED"),
        ("a failed switch closes the next session and keeps the current", [S, O, O2, C2, B, commit, C, X], ["s1", "s2"], "ACCEPTED"),
        ("planted: a third open while a switch is pending", [S, O, O2, ("Open", "s3", "none")], ["s1", "s2", "s3"], "REJECTED"),
        ("planted: a turn starts while a switch is pending", [S, O, O2, B], ["s1", "s2"], "REJECTED"),
        ("planted: a turn ends that never began", [S, O, commit], ["s1"], "REJECTED"),
        ("planted: exit with a session open", [S, O, X], ["s1"], "REJECTED"),
        ("planted: a child done after its parent closed", [S, O, B, spawn, commit, C, done], ["s1"], "REJECTED"),
        ("a fork becomes the next session, and closing the source switches to it (D58)", [S, O, B, commit, ("Fork", "s2", "none"), C, B, commit, C2, X], ["s1", "s2"], "ACCEPTED"),
        ("planted: a fork while a turn is open", [S, O, B, ("Fork", "s2", "none")], ["s1", "s2"], "REJECTED"),
        ("planted: a fork into a session that exists", [S, O2, C2, O, ("Fork", "s2", "none")], ["s1", "s2"], "REJECTED"),
    ]
    bad = 0
    with ThreadPoolExecutor(int(os.environ.get("JOBS", "6"))) as pool:
        for (label, _, _, want), (verdict, detail) in zip(cases, pool.map(lambda c: check(c[1], c[2]), cases)):
            ok = verdict == want
            bad += not ok
            print(f"{'ok  ' if ok else 'FAIL'}  {label}: {verdict} (matched {detail}), wanted {want}")
    print(f"selftest: {len(cases) - bad}/{len(cases)} verdicts as required")
    return 1 if bad else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    counts, failed = {}, 0
    with ThreadPoolExecutor(int(os.environ.get("JOBS", "6"))) as pool:
        for path, verdict, detail in pool.map(run, argv[1:]):
            counts[verdict] = counts.get(verdict, 0) + 1
            failed += verdict in ("REJECTED", "TOOL ERROR")
            if verdict != "ACCEPTED":
                print(f"{verdict:10} {path}: {detail}")
    for verdict, n in sorted(counts.items()):
        print(f"{verdict:10} {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
