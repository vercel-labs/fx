#!/usr/bin/env python3
"""Check what real fx runs did against V1Conversion.tla, with TLC.

    check_conversion.py --request REQUEST.json --report DIR
    check_conversion.py --selftest

REQUEST records a real run: {"version": 1, "ids": {"root": ID,
"child": ID or null, "fresh": [ID, ...]}, "observations": [...]}, one
observation per real step, as V1ConversionTrace.tla describes. The verdict
is printed as JSON and kept in DIR with TLC's log and its generated inputs:
ACCEPTED (exit 0) only when TLC reached its sentinel with every observation
matched; REJECTED (1) when TLC ran to the end without matching them all;
INCONCLUSIVE (2) for malformed or empty evidence; TOOL_ERROR (3) otherwise.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TLA = HERE.parent
sys.path.insert(0, str(TLA.parent / "lib"))
from tlc import toolchain  # noqa: E402

KINDS = {"create", "write", "hold", "release", "open", "all", "crash", "open2", "damage", "fresh", "list",
         "recover"}
REQUESTS = {"open", "all", "crash", "open2", "recover"}
ANSWERS = {"none", "opened", "converted", "busy", "unreadable", "notfound",
           "recovered", "healthy", "unsalvageable", "inv2"}
STATUS = {"none", "import", "fresh", "salvage"}
# A member's damage, as the v1 writer's own `fx session recover` judges it.
DAMAGES = {"ok", "salvage", "lost"}
EXIT = {"ACCEPTED": 0, "REJECTED": 1, "INCONCLUSIVE": 2, "TOOL_ERROR": 3}


class Inconclusive(Exception):
    pass


def tla_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def tla_fun(mapping, render):
    return "(" + " @@ ".join(f"{tla_str(k)} :> {render(v)}" for k, v in mapping.items()) + ")"


def model_ids(ids):
    """Real id -> model id: the root "r", the child "c", fresh sessions "n1".."""
    root, child, fresh = ids.get("root"), ids.get("child"), ids.get("fresh", [])
    if not isinstance(root, str) or not root:
        raise Inconclusive("the request names no root id")
    names = {root: "r"}
    if child:
        names[child] = "c"
    for n, fid in enumerate(fresh, 1):
        names[fid] = f"n{n}"
    if len(names) != 1 + bool(child) + len(fresh):
        raise Inconclusive("ids repeat")
    return names


def model_obs(request):
    names = model_ids(request.get("ids", {}))
    obs = request.get("observations")
    if not isinstance(obs, list) or not obs:
        raise Inconclusive("no observations")
    if not any(o.get("k") in REQUESTS for o in obs):
        raise Inconclusive("no request step was observed")
    member = ["r", "c"]
    every = member + sorted(v for v in names.values() if v.startswith("n"))
    out = []
    for n, o in enumerate(obs, 1):
        try:
            k, ans, ans2 = o["k"], o.get("ans", "none"), o.get("ans2", "none")
            if k not in KINDS or ans not in ANSWERS or ans2 not in ANSWERS:
                raise Inconclusive(f"observation {n}: unknown step or answer")
            r = names.get(o.get("r"), "none") if k in REQUESTS else "none"
            if k in REQUESTS and r != "r":
                raise Inconclusive(f"observation {n}: a request names no known root")

            def by_model(field, default, check):
                got = {names[i]: v for i, v in o[field].items() if i in names}
                if len(got) != len(o[field]):
                    raise Inconclusive(f"observation {n}: {field} names an unknown id")
                for v in got.values():
                    check(v)
                return got, default

            def nat(v):
                if not isinstance(v, int) or v < -1:
                    raise Inconclusive(f"observation {n}: a count is not an integer")

            def status(v):
                if v not in STATUS:
                    raise Inconclusive(f"observation {n}: unknown v2 status {v!r}")

            def damage(v):
                if v not in DAMAGES:
                    raise Inconclusive(f"observation {n}: unknown damage {v!r}")

            v1, _ = by_model("v1", 0, nat)
            pub, _ = by_model("pub", "none", status)
            base, _ = by_model("base", 0, nat)
            extra, _ = by_model("extra", 0, nat)
            bad, _ = by_model("bad", "ok", damage)
            listed, held, denied = o["listed"], o.get("held", []), o.get("denied", False)
            if not isinstance(o["dirty"], bool) or not isinstance(listed, list) or not isinstance(held, list) \
                    or not isinstance(denied, bool):
                raise Inconclusive(f"observation {n}: dirty, listed, held or denied is malformed")
            if denied and k not in REQUESTS:
                raise Inconclusive(f"observation {n}: deletes can only be refused during a request")
            if any(names.get(i) not in member for i in held):
                raise Inconclusive(f"observation {n}: held names an id that is not a v1 member")
            unknown = [i for i in listed if i not in names]
            out.append({
                "k": k, "r": r, "ans": ans, "ans2": ans2,
                "v1": {i: v1.get(i, 0) for i in member},
                "pub": {i: pub.get(i, "none") for i in every},
                "base": {i: base.get(i, 0) for i in every},
                "extra": {i: extra.get(i, 0) for i in every},
                "bad": {i: bad.get(i, "ok") for i in member},
                "dirty": o["dirty"],
                "denied": denied,
                "held": sorted(names[i] for i in held),
                # An id the run does not know can never match the model's listing.
                "listed": sorted({names[i] for i in listed if i in names} | ({"unknown"} if unknown else set())),
            })
        except KeyError as missing:
            raise Inconclusive(f"observation {n}: missing {missing}")
    return out, [v for v in every if v.startswith("n")]


def data_module(obs):
    def rec(o):
        return ("[k |-> " + tla_str(o["k"]) + ", r |-> " + tla_str(o["r"]) + ", ans |-> " + tla_str(o["ans"])
                + ", ans2 |-> " + tla_str(o["ans2"])
                + ", v1 |-> " + tla_fun(o["v1"], str) + ", pub |-> " + tla_fun(o["pub"], tla_str)
                + ", base |-> " + tla_fun(o["base"], str) + ", extra |-> " + tla_fun(o["extra"], str)
                + ", bad |-> " + tla_fun(o["bad"], tla_str)
                + ", dirty |-> " + ("TRUE" if o["dirty"] else "FALSE")
                + ", denied |-> " + ("TRUE" if o["denied"] else "FALSE")
                + ", held |-> {" + ", ".join(tla_str(i) for i in o["held"]) + "}"
                + ", listed |-> {" + ", ".join(tla_str(i) for i in o["listed"]) + "}]")
    body = ",\n    ".join(rec(o) for o in obs)
    return f"---- MODULE ConversionData ----\nEXTENDS TLC, Integers, FiniteSets\nObs == <<\n    {body}\n>>\n====\n"


def config(obs, fresh):
    kinds = [o["k"] for o in obs]
    max_v = max([1] + [v for o in obs for v in o["v1"].values()])
    max_extra = max([1] + [v for o in obs for v in o["extra"].values()])
    writes = sum(k in {"create", "write", "hold"} for k in kinds) + 1
    crashes = sum(k in {"crash", "release"} for k in kinds) + 3 * sum(o["denied"] for o in obs) + 1
    reqs = sum(2 if k == "open2" else 1 for k in kinds if k in REQUESTS)
    fresh_set = "{" + ", ".join(tla_str(f) for f in fresh) + "}"
    return (f'CONSTANTS\n    Procs = {{"p1", "p2"}}\n    RootId = "r"\n    ChildId = "c"\n    NewIds = {fresh_set}\n    None = None\n'
            f"    Torn = Torn\n    MaxV = {max_v}\n    MaxLocks = {writes}\n    MaxExtra = {max_extra}\n"
            f"    MaxCrash = {crashes}\n    MaxReq = {reqs}\n    AvoidV1Ids = TRUE\n"
            "SPECIFICATION TraceSpec\nINVARIANT NotDone\nCONSTRAINT Progress\n")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run_tlc(obs, fresh, work):
    work.mkdir(parents=True)
    (work / "tmp").mkdir()
    for name in ("V1Conversion.tla",):
        shutil.copyfile(TLA / name, work / name)
    shutil.copyfile(HERE / "V1ConversionTrace.tla", work / "V1ConversionTrace.tla")
    (work / "ConversionData.tla").write_text(data_module(obs))
    (work / "V1ConversionTrace.cfg").write_text(config(obs, fresh))
    java, jar = toolchain()
    command = [java, "-XX:+UseParallelGC", f"-Djava.io.tmpdir={work / 'tmp'}", "-cp", jar, "tlc2.TLC",
               "-workers", "1", "-deadlock", "-metadir", str(work / "states"),
               "-config", "V1ConversionTrace.cfg", "V1ConversionTrace"]
    with (work / "tlc.log").open("w") as log:
        code = subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=600).returncode
    text = (work / "tlc.log").read_text(errors="replace")
    matched = max([int(m) for m in re.findall(r'"matched_lines", (\d+)', text)] or [0])
    expected = len(obs)
    if code == 12 and "Invariant NotDone is violated" in text and matched == expected:
        verdict = "ACCEPTED"
    elif code == 0 and "No error has been found" in text and matched < expected:
        verdict = "REJECTED"
    else:
        verdict = "TOOL_ERROR"
    shutil.rmtree(work / "states", ignore_errors=True)
    shutil.rmtree(work / "tmp", ignore_errors=True)
    return {"verdict": verdict, "matched": matched, "expected": expected, "exitCode": code,
            "log": str(work / "tlc.log"),
            "modelHashes": {n: sha256(work / n) for n in ("V1Conversion.tla", "V1ConversionTrace.tla")}}


def verify(request, report):
    if request.get("version") != 1:
        raise Inconclusive("version 1 required")
    obs, fresh = model_obs(request)
    result = run_tlc(obs, fresh, report / "tlc")
    if result["verdict"] == "REJECTED":
        step = obs[result["matched"]]
        result["detail"] = (f"observations 1..{result['matched']} match; observation {result['matched'] + 1} "
                            f"({step['k']}, answer {step['ans']}) is not a behavior of V1Conversion")
    return result


def selftest():
    """Planted observation sequences: each must get its verdict."""
    ids = {"root": "R", "child": None, "fresh": []}

    def ob(k, v1=0, pub="none", base=0, extra=0, ans="none", dirty=False, listed=None, bad="ok", r="R", held=(),
           denied=False, ans2="none", salvaged=None):
        # `salvaged`: the status of the fresh id S a salvage copies into.
        fresh = {} if salvaged is None else {"S": salvaged}
        return {"k": k, "r": r, "ans": ans, "ans2": ans2, "v1": {"R": v1}, "pub": {"R": pub, **fresh},
                "base": {"R": base, **{i: 0 for i in fresh}}, "extra": {"R": extra, **{i: 0 for i in fresh}},
                "bad": {"R": bad}, "dirty": dirty, "held": list(held),
                "listed": ["R"] if listed is None else listed, "denied": denied}
    made = ob("create", v1=1)
    kept = ob("open", v1=1, pub="import", base=1, ans="opened", denied=True)
    cases = [
        ("an open converts the v1 session and deletes it, then a turn lands in v2",
         [made, ob("open", pub="import", base=1, extra=1, ans="opened")], "ACCEPTED"),
        ("convert-all, then an open of the converted session",
         [made, ob("all", pub="import", base=1, ans="converted"),
          ob("open", pub="import", base=1, ans="opened")], "ACCEPTED"),
        ("busy while an older build holds it, opened once released",
         [made, ob("hold", v1=1, held=["R"]), ob("open", v1=1, ans="busy", held=["R"]), ob("release", v1=1),
          ob("open", pub="import", base=1, ans="opened")], "ACCEPTED"),
        ("unreadable: refused, nothing converted or deleted",
         [made, ob("damage", v1=1, bad="lost"), ob("open", v1=1, bad="lost", ans="unreadable")], "ACCEPTED"),
        ("a refused delete leaves the folder; the next open deletes it",
         [made, kept, ob("open", pub="import", base=1, ans="opened")], "ACCEPTED"),
        ("an older build changes a leftover; the next open keeps it, and v2 keeps its copy",
         [made, kept, ob("write", v1=2, pub="import", base=1),
          ob("open", v1=2, pub="import", base=1, ans="opened")], "ACCEPTED"),
        ("a crash mid-conversion leaves staging; the next open sweeps it",
         [made, ob("crash", v1=1, dirty=True), ob("open", pub="import", base=1, ans="opened")], "ACCEPTED"),
        ("two processes open it at once: one converts, both open the copy",
         [made, ob("open2", pub="import", base=1, ans="opened", ans2="opened")], "ACCEPTED"),
        ("planted: of two processes opening it at once, one calls it unreadable",
         [made, ob("open2", pub="import", base=1, ans="opened", ans2="unreadable")], "REJECTED"),
        ("planted: a live v1 session reported missing",
         [made, ob("open", v1=1, ans="notfound")], "REJECTED"),
        ("planted: the copy matches no v1 version",
         [made, ob("open", pub="import", base=-1, ans="opened")], "REJECTED"),
        ("planted: busy with no holder",
         [made, ob("open", v1=1, ans="busy")], "REJECTED"),
        ("planted: the listing hides an unconverted v1 session",
         [made, ob("list", v1=1, listed=[]), ob("open", pub="import", base=1, ans="opened")], "REJECTED"),
        ("planted: unreadable, yet half converted",
         [made, ob("damage", v1=1, bad="lost"), ob("open", v1=1, bad="lost", dirty=True, ans="unreadable")], "REJECTED"),
        ("planted: an older build's later write reaches the v2 copy",
         [made, kept, ob("write", v1=2, pub="import", base=2)], "REJECTED"),
        ("planted: converted with no request",
         [made, ob("list", v1=1, pub="import", base=1), ob("open", pub="import", base=1, ans="opened")], "REJECTED"),
        ("planted: the v1 folder stays though no delete was refused",
         [made, ob("open", v1=1, pub="import", base=1, ans="opened")], "REJECTED"),
        ("planted: a leftover an older build changed is deleted",
         [made, kept, ob("write", v1=2, pub="import", base=1), ob("open", pub="import", base=1, ans="opened")],
         "REJECTED"),
        ("planted: the v1 folder deleted before its copy was published",
         [made, ob("crash", dirty=True)], "REJECTED"),
    ]
    # Salvage (D64): the copy lands in the fresh id S; the v1 session stays.
    salvage_ids = {"root": "R", "child": None, "fresh": ["S"]}
    broken = ob("damage", v1=1, bad="salvage", salvaged="none")
    lost = ob("damage", v1=1, bad="lost", salvaged="none")
    salvage_cases = [
        ("salvage copies a damaged root's start into a fresh session and keeps the v1 session",
         [ob("create", v1=1, salvaged="none"), broken,
          ob("recover", v1=1, bad="salvage", ans="recovered", salvaged="salvage", listed=["R", "S"])], "ACCEPTED"),
        ("salvage of a healthy root changes nothing",
         [ob("create", v1=1, salvaged="none"), ob("recover", v1=1, ans="healthy", salvaged="none")], "ACCEPTED"),
        ("salvage reports damage it cannot get past and changes nothing",
         [ob("create", v1=1, salvaged="none"), lost,
          ob("recover", v1=1, bad="lost", ans="unsalvageable", salvaged="none")], "ACCEPTED"),
        ("planted: salvage refuses a root v1 could salvage",
         [ob("create", v1=1, salvaged="none"), broken,
          ob("recover", v1=1, bad="salvage", ans="unsalvageable", salvaged="none")], "REJECTED"),
        ("planted: salvage deletes the damaged v1 session",
         [ob("create", v1=1, salvaged="none"), broken,
          ob("recover", bad="salvage", ans="recovered", salvaged="salvage", listed=["S"])], "REJECTED"),
        ("planted: salvage converts the damaged root in place",
         [ob("create", v1=1, salvaged="none"), broken,
          ob("recover", v1=1, pub="import", base=1, bad="salvage", ans="recovered", salvaged="none")], "REJECTED"),
    ]
    cases = [(label, ids, o, want) for label, o, want in cases] + \
            [(label, salvage_ids, o, want) for label, o, want in salvage_cases]
    bad = 0
    root = Path(tempfile.mkdtemp(prefix="check-conversion-selftest-"))
    for n, (label, case_ids, observations, want) in enumerate(cases, 1):
        try:
            got = verify({"version": 1, "ids": case_ids, "observations": observations}, root / str(n))
            verdict = got["verdict"]
        except Inconclusive as why:
            verdict = f"INCONCLUSIVE ({why})"
        ok = verdict == want
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'}  {label}: {verdict}, wanted {want}")
    print(f"selftest: {len(cases) - bad}/{len(cases)} verdicts as required")
    if not bad:
        shutil.rmtree(root, ignore_errors=True)
    return 1 if bad else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.request or not args.report:
        parser.error("--request and --report are required")
    report = args.report.resolve()
    report.mkdir(parents=True, exist_ok=False)
    try:
        raw = args.request.read_bytes()
        (report / "request.json").write_bytes(raw)
        result = verify(json.loads(raw), report)
    except Inconclusive as why:
        result = {"verdict": "INCONCLUSIVE", "detail": str(why)}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result = {"verdict": "TOOL_ERROR", "detail": str(error)}
    result["version"] = 1
    result["report"] = str(report)
    (report / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return EXIT[result["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
