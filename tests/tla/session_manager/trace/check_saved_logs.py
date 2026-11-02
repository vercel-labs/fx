#!/usr/bin/env python3
"""Checks logs fx saved against TurnLifecycle.tla and Subagents.tla.

usage: check_saved_logs.py ROOT...    each ROOT holds session folders
                                      ({id}/log.jsonl), as ~/.fx/sessions/v2
       check_saved_logs.py --selftest planted logs: each must get its verdict

JOBS=N runs N TLC checks at once (default 6).

Every session's log is checked against TurnLifecycle (TurnLifecycleLog.tla);
a log with child lines is also checked against Subagents (SubagentsLog.tla),
with each child's log existence read at the end. Only the disk is known, so
TLC searches the process state in between (see the two wrappers). A torn
tail is left out, as the manager reads it. A log that does not parse is
reported as unreadable, not checked. Exit 0 when every readable log is
accepted.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
TLA = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(os.path.dirname(TLA), "lib"))
from tlc import toolchain  # noqa: E402

TURN_KINDS = {
    "session_created": "created",
    "set": "set",
    "turn_started": "start",
    "item": "item",
    "compacted": "compacted",
    "turn_committed": "commit",
    "turn_interrupted": "interrupt",
    "closed": "closed",
}
CHILD_KINDS = {"child_spawned", "child_finished"}
OUTSIDE = {"snapshot"} | CHILD_KINDS


class Unreadable(Exception):
    pass


def read_lines(path, raw=False):
    """The log's whole lines; a torn tail is left out. With `raw`, each line
    comes with its exact bytes."""
    data = open(path, "rb").read()
    end = data.rfind(b"\n")
    out = []
    for n, line in enumerate(data[: end + 1].split(b"\n")[:-1], 1):
        try:
            value = json.loads(line)
        except ValueError:
            raise Unreadable(f"line {n} is not JSON")
        out.append((value, line) if raw else value)
    return out


def fork_records(lines, upto=None):
    """[k, h] records of lines 2.. (those with seq <= `upto`), snapshots left
    out: a fork encodes its copied snapshots again."""
    out = []
    for value, line in lines[1:]:
        if upto is not None and value.get("seq", 0) > upto:
            break
        kind = value.get("kind")
        if kind == "snapshot":
            continue
        out.append({"k": TURN_KINDS.get(kind, kind), "h": hashlib.sha256(line).hexdigest()[:16]})
    return out


def fork_target(lines, root):
    """For a fork, its copied lines and its source's lines; else None."""
    origin = lines[0][0].get("forked_from")
    if not origin:
        return None
    source = os.path.join(root, origin["id"], "log.jsonl")
    if not os.path.isfile(source):
        raise Unreadable(f"fork source {origin['id']} is not in this root")
    return fork_records(lines, origin["seq"]), fork_records(read_lines(source, raw=True))


def turn_target(lines):
    target = []
    for n, line in enumerate(lines, 1):
        kind = line.get("kind")
        if kind in OUTSIDE:
            continue
        if kind not in TURN_KINDS:
            raise Unreadable(f"line {n} has unknown kind {kind!r}")
        target.append(TURN_KINDS[kind])
    return target


def child_target(lines, root):
    names, works, target = {}, {}, []
    for line in lines:
        kind = line.get("kind")
        if kind not in CHILD_KINDS:
            continue
        child = line["child"]
        c = names.setdefault(child, f"c{len(names) + 1}")
        if kind == "child_spawned":
            works[c] = works.get(c, 0) + 1
            target.append({"k": "spawned", "c": c, "w": works[c], "o": "none"})
        else:
            target.append({"k": "finished", "c": c, "w": works.get(c, 0), "o": line["outcome"]})
    final = {c: os.path.exists(os.path.join(root, child, "log.jsonl")) for child, c in names.items()}
    return target, final


def tla_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def tla_record(r):
    return "[" + ", ".join(f"{k} |-> {tla_str(v) if isinstance(v, str) else v}" for k, v in r.items()) + "]"


def run_tlc(module, spec_files, generated, cfg, invariant="NotWritten"):
    work = tempfile.mkdtemp(prefix="fx-log-check-")
    try:
        for f in spec_files:
            shutil.copy(f, work)
        for name, text in generated.items():
            open(os.path.join(work, name), "w").write(text)
        open(os.path.join(work, module + ".cfg"), "w").write(cfg)
        java, jar = toolchain()
        proc = subprocess.run(
            # Its own java.io.tmpdir: TLC unpacks its standard modules there,
            # and parallel runs sharing one folder read each other's
            # half-written files.
            [java, "-XX:+UseParallelGC", f"-Djava.io.tmpdir={work}", "-cp", jar, "tlc2.TLC", "-workers", "1", "-deadlock",
             "-metadir", os.path.join(work, "states"), "-config", module + ".cfg", module],
            cwd=work, capture_output=True, text=True, timeout=600,
        )
        out = proc.stdout + proc.stderr
        matched = max([int(m) for m in re.findall(r'"matched_lines", (\d+)', out)] or [0])
        if f"Invariant {invariant} is violated" in out:
            return "ACCEPTED", matched
        if "No error has been found" in out:
            return "REJECTED", matched
        return "TOOL ERROR", out[-600:]
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check_turns(target):
    body = ", ".join(tla_str(k) for k in target)
    saved = f"---- MODULE SavedLog ----\nTarget == <<{body}>>\n====\n"
    cfg = (f"CONSTANT MaxLen = {len(target) + 2}\nSPECIFICATION LogSpec\n"
           "INVARIANT NotWritten\nCONSTRAINT Progress\n")
    specs = [os.path.join(TLA, "TurnLifecycle.tla"), os.path.join(HERE, "TurnLifecycleLog.tla")]
    return run_tlc("TurnLifecycleLog", specs, {"SavedLog.tla": saved}, cfg)


def check_children(target, final):
    children = sorted(final)
    body = ", ".join(tla_record(r) for r in target)
    fin = " @@ ".join(f"{tla_str(c)} :> {'TRUE' if final[c] else 'FALSE'}" for c in children)
    saved = (f"---- MODULE SavedChildren ----\nEXTENDS TLC\nTarget == <<{body}>>\n"
             f"FinalChildLog == {fin}\n====\n")
    max_work = max([r["w"] for r in target] or [1])
    cfg = ("CONSTANTS Children = {" + ", ".join(tla_str(c) for c in children) + "}\n"
           f"          MaxWork = {max_work}\nSPECIFICATION LogSpec\n"
           "INVARIANT NotWritten\nCONSTRAINT Progress\n")
    specs = [os.path.join(TLA, "Subagents.tla"), os.path.join(HERE, "SubagentsLog.tla")]
    return run_tlc("SubagentsLog", specs, {"SavedChildren.tla": saved}, cfg)


def check_fork(copied, source):
    def seq(rs):
        return ", ".join(tla_record(r) for r in rs)
    saved = f"---- MODULE SavedFork ----\nCopied == <<{seq(copied)}>>\nSource == <<{seq(source)}>>\n====\n"
    cfg = "SPECIFICATION LogSpec\nINVARIANT NotWritten\n"
    verdict, _ = run_tlc("ForkLog", [os.path.join(HERE, "ForkLog.tla")], {"SavedFork.tla": saved}, cfg)
    return verdict, len(copied)


def jobs_for(roots):
    jobs = []
    for root in roots:
        for sid in sorted(os.listdir(root)):
            path = os.path.join(root, sid, "log.jsonl")
            if not os.path.isfile(path):
                continue
            name = f"{os.path.basename(os.path.dirname(root.rstrip('/')))}/{sid}"
            try:
                raw = read_lines(path, raw=True)
                lines = [value for value, _ in raw]
                turns = turn_target(lines)
                children = child_target(lines, root)
                fork = fork_target(raw, root)
            except Unreadable as err:
                jobs.append((name, "unreadable", str(err)))
                continue
            jobs.append((name, "turns", turns))
            if children[0]:
                jobs.append((name, "children", children))
            if fork:
                jobs.append((name, "fork", fork))
    return jobs


def run(job):
    name, what, arg = job
    if what == "unreadable":
        return name, what, "UNREADABLE", arg
    if what == "turns":
        verdict, detail = check_turns(arg)
    elif what == "fork":
        verdict, detail = check_fork(*arg)
    else:
        verdict, detail = check_children(*arg)
    size = len(arg) if what == "turns" else len(arg[0])
    return name, what, verdict, f"{detail}/{size} lines" if verdict != "TOOL ERROR" else detail


def selftest():
    cases = [
        ("turns: a committed turn, then close", "turns", ["created", "set", "start", "item", "commit", "closed"], "ACCEPTED"),
        ("turns: crash, reopen interrupts, next turn", "turns", ["created", "start", "item", "interrupt", "start", "commit"], "ACCEPTED"),
        ("turns: close interrupts the open turn", "turns", ["created", "start", "interrupt", "closed", "start", "commit"], "ACCEPTED"),
        ("planted: item outside a turn", "turns", ["created", "item"], "REJECTED"),
        ("planted: two open turns", "turns", ["created", "start", "start"], "REJECTED"),
        ("planted: closed inside a turn", "turns", ["created", "start", "closed"], "REJECTED"),
        ("planted: commit without a start", "turns", ["created", "set", "commit"], "REJECTED"),
        ("children: spawn, finish ok",
         "children", ([{"k": "spawned", "c": "c1", "w": 1, "o": "none"}, {"k": "finished", "c": "c1", "w": 1, "o": "ok"}], {"c1": True}), "ACCEPTED"),
        ("children: lost, then a fresh start (D33)",
         "children", ([{"k": "spawned", "c": "c1", "w": 1, "o": "none"}, {"k": "finished", "c": "c1", "w": 1, "o": "lost"},
                       {"k": "spawned", "c": "c1", "w": 2, "o": "none"}, {"k": "finished", "c": "c1", "w": 2, "o": "ok"}], {"c1": True}), "ACCEPTED"),
        ("planted: lost, yet the child has a log",
         "children", ([{"k": "spawned", "c": "c1", "w": 1, "o": "none"}, {"k": "finished", "c": "c1", "w": 1, "o": "lost"}], {"c1": True}), "REJECTED"),
        ("planted: interrupted, yet the child has no log",
         "children", ([{"k": "spawned", "c": "c1", "w": 1, "o": "none"}, {"k": "finished", "c": "c1", "w": 1, "o": "interrupted"}], {"c1": False}), "REJECTED"),
        ("planted: a finish with no spawn",
         "children", ([{"k": "finished", "c": "c1", "w": 0, "o": "ok"}], {"c1": False}), "REJECTED"),
    ]
    def rec(k, h):
        return {"k": k, "h": h}
    src = [rec("set", "p"), rec("start", "a"), rec("item", "b"), rec("commit", "c"), rec("start", "d"), rec("commit", "e")]
    cases += [
        ("fork: the source's lines to the end of turn 1", "fork", (src[:4], src), "ACCEPTED"),
        ("fork: before the first turn", "fork", (src[:1], src), "ACCEPTED"),
        ("planted: a copied line differs from the source's", "fork", (src[:2] + [rec("item", "x"), src[3]], src), "REJECTED"),
        ("planted: the copy ends inside a turn", "fork", (src[:3], src), "REJECTED"),
    ]
    bad = 0

    def verdict_of(c):
        if c[1] == "turns":
            return check_turns(c[2])
        if c[1] == "fork":
            return check_fork(*c[2])
        return check_children(*c[2])
    with ThreadPoolExecutor(int(os.environ.get("JOBS", "6"))) as pool:
        results = pool.map(lambda c: (c, verdict_of(c)), cases)
        for (label, _, _, want), (verdict, detail) in results:
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
    jobs = jobs_for(argv[1:])
    counts = {}
    failed = 0
    with ThreadPoolExecutor(int(os.environ.get("JOBS", "6"))) as pool:
        for name, what, verdict, detail in pool.map(run, jobs):
            counts[(what, verdict)] = counts.get((what, verdict), 0) + 1
            if verdict not in ("ACCEPTED", "UNREADABLE"):
                failed += 1
            if verdict != "ACCEPTED":
                print(f"{verdict:10} {what:9} {name}: {detail}")
    for (what, verdict), n in sorted(counts.items()):
        print(f"{what:9} {verdict:10} {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
