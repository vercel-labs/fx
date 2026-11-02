#!/usr/bin/env python3
"""Check that every spec still catches the bugs it exists to catch.

Each mutant plants one realistic design bug in a temporary copy of a spec
and runs TLC on it. The run passes only if TLC reports the expected
invariant as violated. Run after changing any spec:

    ./mutants.py
    ./mutants.py Journal Fencing     # only these specs

Needs the same Java runtime and tla2tools.jar as check.sh.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
JAR = os.environ.get("TLA2TOOLS_JAR", os.path.expanduser("~/.local/share/tla/tla2tools.jar"))

# (spec, bug, [(text to replace, replacement), ...], invariant that must fail)
# The last field may be a tuple when the bug breaks several invariants; any
# one of them counts. An optional fifth field lists invariants to add to the
# .cfg for that run; a witness uses it with no edits to prove a behavior is
# reachable. Mutants run TLC with one worker so the first violation reported
# is deterministic.
MUTANTS = [
    # Journal.tla
    ("Journal", "pass a barrier before the World acknowledges it",
     [("    /\\ acked >= waiting\n", "")],
     "PassedBarriersDurable"),
    ("Journal", "acknowledge writes that were only sent",
     [("    /\\ acked < Len(durable)\n    /\\ acked' = acked + 1",
       "    /\\ acked < sent\n    /\\ acked' = acked + 1")],
     "AckedAreDurable"),
    ("Journal", "keep run-ahead state after a rejected write",
     [("    /\\ sent' = Len(durable)\n    /\\ mem' = durable\n"
       "    /\\ UNCHANGED <<alive, durable, passed, nextId, crashes>>",
       "    /\\ UNCHANGED <<alive, durable, passed, nextId, crashes, sent, mem>>")],
     "PipelineInOrder"),
    ("Journal", "the World persists pipelined writes out of order",
     [("    /\\ durable' = Append(durable, Head(queue))\n    /\\ queue' = Tail(queue)",
       "    /\\ durable' = Append(durable, queue[Len(queue)])\n"
       "    /\\ queue' = SubSeq(queue, 1, Len(queue) - 1)")],
     "PipelineInOrder"),
    ("Journal", "restore while the dead process's writes are still in flight",
     [("    /\\ ~alive\n    /\\ queue = <<>>\n", "    /\\ ~alive\n")],
     "PipelineInOrder"),

    # ToolReplay.tla
    ("ToolReplay", "a never tool starts before its intent is durable",
     [("    /\\ (c \\in jIntent \\/ Policy[c] = \"safe\")\n", "")],
     "NeverStartsWithoutDurableIntent"),
    ("ToolReplay", "restore treats a never tool like a safe one and runs it again",
     [("ELSE IF c \\in jIntent /\\ Policy[c] = \"safe\" THEN \"may_run\"",
       "ELSE IF c \\in jIntent THEN \"may_run\""),
      ("IF jOutcome[c] = \"none\" /\\ c \\in jIntent /\\ Policy[c] = \"never\"\n"
       "                      THEN \"interrupted\"",
       "IF FALSE\n                      THEN \"interrupted\""),
      ("IF jOutcome[c] = \"none\" /\\ c \\in jIntent /\\ Policy[c] = \"never\"\n"
       "                           THEN outcomeWrites[c] + 1",
       "IF FALSE\n                           THEN outcomeWrites[c] + 1")],
     "NeverRunsTwice"),
    ("ToolReplay", "restore ignores a durable result",
     [("IF jOutcome[c] # \"none\" THEN \"resolved\"",
       "IF FALSE THEN \"resolved\"")],
     "NoStartAfterOutcome"),
    ("ToolReplay", "restore marks a safe tool interrupted",
     [("IF jOutcome[c] = \"none\" /\\ c \\in jIntent /\\ Policy[c] = \"never\"\n"
       "                      THEN \"interrupted\"",
       "IF jOutcome[c] = \"none\" /\\ c \\in jIntent\n"
       "                      THEN \"interrupted\"")],
     "InterruptedMeansUnknown"),

    # Fencing.tla
    ("Fencing", "append without the position check: two processes both win the intent",
     [("    IF Len(log) = view[p]\n    THEN", "    IF TRUE\n    THEN")],
     "OneIntent"),
    ("Fencing", "a fenced process keeps running its tool",
     [("    /\\ status[p] = \"active\"\n    /\\ pc[p] = \"may_run\"",
       "    /\\ pc[p] = \"may_run\"")],
     "FencedNeverActs"),
    # Breaks two invariants: a second run, and a result written by a process
    # that did not win the intent. Either report counts.
    ("Fencing", "recover runs the tool again instead of recording interrupted",
     [("    /\\ CasAppend(p, \"interrupted\", \"idle\")",
       "    /\\ CasAppend(p, \"step\", \"may_run\")")],
     ("AtMostOneRun", "ResultByRunner")),

    # Inbox.tla
    ("Inbox", "resolve the caller's promise before the input is durable",
     [("    /\\ i \\in jAccepted\n    /\\ i \\notin acked",
       "    /\\ i \\in submitted\n    /\\ i \\notin acked")],
     "AckedAreDurable"),
    ("Inbox", "send the model an input that is only in memory",
     [("\\E S \\in SUBSET memPending :", "\\E S \\in SUBSET (memPending \\cup submitted) :")],
     "ActedInputsAreJournaled"),
    ("Inbox", "withdraw without checking placement",
     [("    /\\ IF jPlaced[i] # 0\n", "    /\\ IF FALSE\n")],
     "WithdrawnNeverPlaced"),
    ("Inbox", "restore forgets where inputs were placed",
     [("{i \\in jAccepted : jPlaced[i] = 0 /\\ i \\notin jWithdrawn}",
       "{i \\in jAccepted : i \\notin jWithdrawn}")],
     "PlacedOnce"),

    # Resumption.tla
    ("Resumption", "fx -c asks the user after an unclean exit",
     [("THEN /\\ autoResumes' = autoResumes + 1\n"
       "            /\\ IF reply = \"saved\"\n"
       "               THEN /\\ delivered' = delivered + 1\n"
       "                    /\\ UNCHANGED notices\n"
       "               ELSE /\\ notices' = notices + 1\n"
       "                    /\\ UNCHANGED delivered\n"
       "            /\\ UNCHANGED asked",
       "THEN /\\ asked' = TRUE\n"
       "            /\\ UNCHANGED <<autoResumes, notices, delivered>>")],
     "NeverAsks"),
    ("Resumption", "a crash-loop guard: stop resuming after the first resume",
     [("IF turn = \"open\"\n       THEN", "IF turn = \"open\" /\\ autoResumes < 1\n       THEN")],
     "EveryCrashResumed"),
    ("Resumption", "resume a turn the user stopped",
     [("IF turn = \"open\"\n       THEN", "IF turn \\in {\"open\", \"user_stopped\"}\n       THEN")],
     "NeverResumeFinishedTurn"),
    ("Resumption", "resume without telling the model",
     [("/\\ notices' = notices + 1", "/\\ notices' = notices")],
     "ModelToldEveryTime"),
    ("Resumption", "resume restarts a reply it saved and asks the model again",
     [("            /\\ IF reply = \"saved\"\n", "            /\\ IF FALSE\n"),
      ("    /\\ UNCHANGED <<turn, turns, crashesInTurn, crashes, reply, ending,\n",
       "    /\\ reply' = \"none\"\n    /\\ UNCHANGED <<turn, turns, crashesInTurn, crashes, ending,\n")],
     "SavedAnswerNotRequested"),
    ("Resumption", "turn.result resolves while the turn's end is still being stored",
     [("    /\\ turn = \"committed\"\n    /\\ resolved' = TRUE",
       "    /\\ (turn = \"committed\" \\/ ending)\n    /\\ resolved' = TRUE")],
     "ResultOnlyAfterDurableEnd"),
    ("Resumption", "fault injection: a crash loses the saved reply",
     [("    /\\ ending' = FALSE\n    /\\ UNCHANGED <<turn, turns, autoResumes, asked, notices, delivered,\n"
       "                   badResume, reply, resolved,",
       "    /\\ ending' = FALSE\n    /\\ reply' = \"none\"\n"
       "    /\\ UNCHANGED <<turn, turns, autoResumes, asked, notices, delivered,\n"
       "                   badResume, resolved,")],
     "SavedAnswerNotRequested"),
    # Witness: no code change; NoDelivery is added to the .cfg and must be
    # violated, proving that a resume really delivers a saved reply.
    ("Resumption", "witness: a resume delivers a saved reply",
     [], "NoDelivery", ["NoDelivery"]),

    # ParallelBatch.tla
    ("ParallelBatch", "a writer starts while earlier calls still run",
     [("    /\\ i \\in Writes => \\A j \\in 1..(i - 1) : status[j] = \"done\"\n", "")],
     ("WriterRunsAlone", "WriterAfterEarlier")),
    ("ParallelBatch", "a later call starts before an earlier writer finished",
     [("    /\\ \\A j \\in 1..(i - 1) : j \\in Writes => status[j] = \"done\"\n", "")],
     ("WriterRunsAlone", "NothingPassesWriter")),
    ("ParallelBatch", "results reported in completion order (list-then-read breaks)",
     [("    /\\ status[Len(reported) + 1] = \"done\"\n"
       "    /\\ reported' = Append(reported, Len(reported) + 1)",
       "    /\\ \\E i \\in Calls : /\\ status[i] = \"done\"\n"
       "                        /\\ \\A k \\in 1..Len(reported) : reported[k] # i\n"
       "                        /\\ reported' = Append(reported, i)")],
     "ResultsInModelOrder"),
    ("ParallelBatch", "fault injection: a crash drops a durable result",
     [("IF status[i] = \"done\" THEN \"done\" ELSE \"waiting\"", "\"waiting\"")],
     "ResultsInModelOrder"),
    # Witness: no code change; NoReaderOverlap is added to the .cfg and must
    # be violated, proving that readers really run in parallel by default.
    ("ParallelBatch", "witness: two readers run at the same time",
     [], "NoReaderOverlap", ["NoReaderOverlap"]),

    # SnapshotTail.tla
    ("SnapshotTail", "store a snapshot of events that are not durable yet",
     [("\\E at \\in 0..dlen :", "\\E at \\in 0..Len(log) :")],
     "SnapshotNotAhead"),
    ("SnapshotTail", "snapshot stores the whole log's state under an earlier position",
     [("state |-> Fold(SubSeq(log, 1, at))", "state |-> Fold(log)")],
     "SnapshotMatchesPrefix"),
    ("SnapshotTail", "restore skips the events after the snapshot",
     [("RestoreFrom(snap) == FoldFrom(snap.state, log, snap.at + 1)",
       "RestoreFrom(snap) == snap.state")],
     "ResumeEqualsFullReplay"),
    ("SnapshotTail", "off by one: restore replays the snapshot's last event again",
     [("FoldFrom(snap.state, log, snap.at + 1)",
       "FoldFrom(snap.state, log, IF snap.at = 0 THEN 1 ELSE snap.at)")],
     "ResumeEqualsFullReplay"),
    ("SnapshotTail", "a trimming store keeps a late, older snapshot (the first createMemoryJournal)",
     [("""        IF s.at > latest.at
        THEN /\\ latest' = s
             /\\ trimmed' = s.at
        ELSE UNCHANGED <<latest, trimmed>>""",
       """        /\\ latest' = s
        /\\ trimmed' = IF s.at > trimmed THEN s.at ELSE trimmed""")],
     "SnapshotsMoveForward"),
]


def find_java():
    candidates = []
    if os.environ.get("JAVA_HOME"):
        candidates.append(os.path.join(os.environ["JAVA_HOME"], "bin", "java"))
    candidates += ["/opt/homebrew/opt/openjdk/bin/java", "/usr/local/opt/openjdk/bin/java"]
    on_path = shutil.which("java")
    if on_path:
        candidates.append(on_path)
    for candidate in candidates:
        if os.access(candidate, os.X_OK):
            probe = subprocess.run([candidate, "-version"], capture_output=True)
            if probe.returncode == 0:
                return candidate
    sys.exit("no working Java runtime (set JAVA_HOME or brew install openjdk)")


def run_mutant(java, spec, edits, workdir, extra_invariants=()):
    text = (HERE / f"{spec}.tla").read_text()
    for old, new in edits:
        count = text.count(old)
        if count != 1:
            return None, f"replacement text found {count} times, expected once: {old!r}"
        text = text.replace(old, new)
    (workdir / f"{spec}.tla").write_text(text)
    cfg = (HERE / f"{spec}.cfg").read_text()
    if extra_invariants:
        # Every .cfg here ends with its INVARIANTS (or PROPERTIES) section.
        cfg = cfg.rstrip("\n") + "\n" + "".join(f"    {name}\n" for name in extra_invariants)
    (workdir / f"{spec}.cfg").write_text(cfg)
    result = subprocess.run(
        [java, "-XX:+UseParallelGC", "-cp", JAR, "tlc2.TLC", "-deadlock", "-workers", "1",
         "-cleanup", "-metadir", str(workdir / "states"), "-config", f"{spec}.cfg", f"{spec}.tla"],
        cwd=workdir, capture_output=True, text=True)
    return result.stdout + result.stderr, None


def main():
    if not os.path.isfile(JAR):
        sys.exit(f"tla2tools.jar not found at {JAR} (set TLA2TOOLS_JAR)")
    java = find_java()
    only = set(sys.argv[1:])
    failures = 0
    selected = [m for m in MUTANTS if not only or m[0] in only]
    for spec, bug, edits, expected, *extra in selected:
        accepted = expected if isinstance(expected, tuple) else (expected,)
        with tempfile.TemporaryDirectory(prefix="workflows-mutant-") as tmp:
            output, problem = run_mutant(java, spec, edits, pathlib.Path(tmp),
                                         extra[0] if extra else ())
        hit = None if problem else next(
            (name for name in accepted if f"Invariant {name} is violated" in output), None)
        if problem:
            print(f"BROKEN  {spec}: {bug}: {problem}")
            failures += 1
        elif hit:
            print(f"caught  {spec}: {bug} -> {hit}")
        else:
            reported = [line for line in output.splitlines() if "violated" in line or "Error" in line]
            print(f"MISSED  {spec}: {bug}: expected {' or '.join(accepted)}; "
                  f"TLC said {reported[:3] or 'no error'}")
            failures += 1
    print(f"{len(selected) - failures}/{len(selected)} mutants caught")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
