#!/usr/bin/env python3
"""Check that every spec still catches the bugs it exists to catch.

Each mutant plants one realistic design bug in a temporary copy of a spec
and runs TLC on it. The run passes only if TLC reports the expected
invariant as violated. Run after changing any spec:

    ./mutants.py

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

# (spec, bug description, text to replace, replacement, invariant that must fail)
MUTANTS = [
    ("Wiring", "a fork reuses a session that exists",
     "    /\\ f \\notin {cur, next}\n    /\\ ~made[f]\n",
     "    /\\ f \\notin {cur, next}\n",
     "ForkIsNewSession"),
    ("Wiring", "a fork while a turn is open",
     "    /\\ ~made[f]\n    /\\ ~turnOpen[cur]\n    /\\ next' = f",
     "    /\\ ~made[f]\n    /\\ next' = f",
     "ForkBetweenTurns"),
    ("Wiring", "the fork step writes the source",
     "    /\\ \\E e \\in Ends : lastEnd' = [lastEnd EXCEPT ![f] = e]",
     "    /\\ \\E e \\in Ends : lastEnd' = [lastEnd EXCEPT ![f] = e, ![cur] = \"interrupt\"]",
     "ForkLeavesSource"),
    ('V1Conversion', 'a converter takes locks another process holds', '    /\\ IF \\A i \\in present : v1lock[i] = "free"\n', '    /\\ IF TRUE\n', 'LockHeld'),
    ('V1Conversion', 'a fresh v2 session takes a live v1 id', '(AvoidV1Ids => v1ver[i] = 0)', 'TRUE', 'NoShadow'),
    ('V1Conversion', 'the root lands before its children', '    /\\ \\A c \\in conv[p].members \\ {r} : ~staged[c]\n', '', 'ChildrenLanded'),
    ('V1Conversion', "a busy answer sweeps another process's staging", '       ELSE /\\ Answer(p, "busy")\n            /\\ UNCHANGED <<v1lock, conv>>\n    /\\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,\n                   stagedBase,', '       ELSE /\\ Answer(p, "busy")\n            /\\ UNCHANGED <<v1lock, conv>>\n    /\\ staged\' = [i \\in Ids |-> FALSE]\n    /\\ UNCHANGED <<v1ver, writing, locks, bad, pub, base,\n                   stagedBase,', 'NothingHalfConverted'),
    ('V1Conversion', "a crash keeps the converter's locks", '    /\\ v1lock\' = [i \\in Ids |-> IF v1lock[i] = p THEN "free" ELSE v1lock[i]]\n', "    /\\ v1lock' = v1lock\n", 'NoStaleConvLock'),
    ('V1Conversion', 'an open reports a live v1 session missing', '    /\\ pub[req[p].root] = "none" /\\ v1ver[req[p].root] = 0\n    /\\ Answer(p, IF', '    /\\ ~Live(req[p].root)\n    /\\ Answer(p, IF', 'NoFalseNotFound'),
    ('V1Conversion', 'a conversion starts without a request', '    LET r == req[p].root\n        present == {i \\in Fam(r) : v1ver[i] > 0} IN\n    /\\ Waiting(p)\n', '    LET r == RootId\n        present == {i \\in Fam(r) : v1ver[i] > 0} IN\n    /\\ conv[p] = Idle\n', 'ConvertsOnlyOnRequest'),
    ('V1Conversion', 'an unreadable member leaves its staging', "            /\\ staged' = [i \\in Ids |-> IF i \\in Fam(conv[p].root) THEN FALSE ELSE staged[i]]\n", "            /\\ staged' = [i \\in Ids |-> IF i \\in copy THEN TRUE ELSE staged[i]]\n", 'NothingHalfConverted'),
    ('V1Conversion', 'a busy answer keeps the locks it took', '       ELSE /\\ Answer(p, "busy")\n            /\\ UNCHANGED <<v1lock, conv>>', '       ELSE /\\ Answer(p, "busy")\n            /\\ v1lock\' = [i \\in Ids |-> IF i \\in present /\\ v1lock[i] = "free" THEN p ELSE v1lock[i]]\n            /\\ UNCHANGED conv', 'NoStaleConvLock'),
    ('V1Conversion', 'a child loses its v1 folder before its root is published', "    /\\ base' = [base EXCEPT ![c] = stagedBase[c]]\n    /\\ UNCHANGED <<v1ver, v1lock,", "    /\\ base' = [base EXCEPT ![c] = stagedBase[c]]\n    /\\ v1ver' = [v1ver EXCEPT ![c] = 0]\n    /\\ UNCHANGED <<v1lock,", 'OrphansKeepV1'),
    ('V1Conversion', 'a cleanup deletes a leftover an older build changed', '    /\\ pub[i] = "import" /\\ v1ver[i] > 0 /\\ v1ver[i] = base[i] /\\ bad[i] = "ok"\n', '    /\\ pub[i] = "import" /\\ v1ver[i] > 0 /\\ bad[i] = "ok"\n', 'NoLossOnDelete'),
    ('V1Conversion', "a cleanup ignores a writer's lock", '    /\\ v1lock[i] = "free" /\\ i \\notin refused[p]', '    /\\ i \\notin refused[p]', 'NoLossOnDelete'),
    ('V1Conversion', 'a conversion keeps the v1 folders', '    /\\ \\A i \\in conv[p].members : ~Deletable(p, i) \\/ i \\in refused[p]\n', '', 'LeftoversGone'),
    ('V1Conversion', 'an open skips the leftover cleanup', '    /\\ ~\\E i \\in Fam(req[p].root) : Leftover(p, i)\n', '', 'LeftoversGone'),
    ('V1Conversion', 'the locks go before the delete', '    /\\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, stagedBase, extra, req,\n                   out, refused, reqs, crashes, keeps>>', '    /\\ v1lock\' = [i \\in Ids |-> IF i \\in conv[p].members THEN "free" ELSE v1lock[i]]\n    /\\ UNCHANGED <<v1ver, writing, locks, bad, stagedBase, extra, req,\n                   out, refused, reqs, crashes, keeps>>', 'LockHeld'),
    ('V1Conversion', 'the converter writes a v1 file', '    /\\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, extra, refused,\n                   reqs, crashes, famOf, keeps>>', "    /\\ bad' = [i \\in Ids |-> IF i \\in conv[p].members THEN \"lost\" ELSE bad[i]]\n    /\\ UNCHANGED <<v1ver, writing, locks, pub, base, extra, refused,\n                   reqs, crashes, famOf, keeps>>", 'ConverterOnlyDeletes'),
    ('V1Conversion', 'a reused child is deleted after an older build changed it', '    /\\ i \\in conv[p].members /\\ v1ver[i] > 0 /\\ v1ver[i] = base[i]\n    /\\ i \\in conv[p].copied', '    /\\ i \\in conv[p].members /\\ v1ver[i] > 0\n    /\\ i \\in conv[p].copied', 'NoLossOnDelete'),
    ('V1Conversion', 'a conversion deletes a v1 folder that keeps a file its copy left out',
     '    /\\ i \\in conv[p].copied \\/ bad[i] = "ok"\n    /\\ i \\notin keeps\n',
     '    /\\ i \\in conv[p].copied \\/ bad[i] = "ok"\n', 'NoLossOnDelete'),
    ('V1Conversion', 'a cleanup deletes a v1 folder that keeps a file its copy left out',
     '    /\\ v1lock[i] = "free" /\\ i \\notin refused[p]\n    /\\ i \\notin keeps\n',
     '    /\\ v1lock[i] = "free" /\\ i \\notin refused[p]\n', 'NoLossOnDelete'),
    ('V1Conversion', 'salvage deletes its damaged source', "                  [] OTHER -> \"unsalvageable\")\n    /\\ UNCHANGED <<v1ver, writing,", "                  [] OTHER -> \"unsalvageable\")\n    /\\ v1ver' = [v1ver EXCEPT ![r] = 0]\n    /\\ UNCHANGED <<writing,", 'NoLossOnDelete'),
    ('V1Conversion', 'salvage writes into the v1 id', '       THEN \\E n \\in free : pub\' = [pub EXCEPT ![n] = "salvage"]', '       THEN pub\' = [pub EXCEPT ![r] = "salvage"]', 'SalvageLeavesSource'),
    ('V1Conversion', 'an open calls a readable family unreadable', '    /\\ IF \\E i \\in copy : bad[i] # "ok"', '    /\\ IF copy # {}', 'RefusedOnlyWithCause'),
    ('V1Conversion', 'salvage refuses a salvageable session', '                  [] bad[r] = "salvage" -> "recovered"\n', '', 'RefusedOnlyWithCause'),
    ('V1Conversion', "salvage ignores a writer's lock", '    /\\ IF v1lock[r] = "free"\n       THEN /\\ v1lock\' = [v1lock EXCEPT ![r] = p]', '    /\\ IF TRUE\n       THEN /\\ v1lock\' = [v1lock EXCEPT ![r] = p]', 'LockHeld'),
    ('V1Conversion', 'a reused child is copied again', "       ELSE /\\ staged' = [i \\in Ids |-> IF i \\in Fam(conv[p].root) THEN i \\in copy ELSE staged[i]]\n            /\\ stagedBase' = [i \\in Ids |->\n                                IF i \\in copy", "       ELSE /\\ staged' = [i \\in Ids |-> IF i \\in Fam(conv[p].root) THEN i \\in m ELSE staged[i]]\n            /\\ stagedBase' = [i \\in Ids |->\n                                IF i \\in m", 'ChildrenStick'),
    ("SessionLog", "fsync acks a half-written line",
     'Fsync ==\n    /\\ status = "open"',
     'Fsync ==\n    /\\ status \\in {"open", "writing"}',
     "AckedSurvive"),
    ("SessionLog", "open() keeps a torn tail",
     "IF LastDone THEN log ELSE SubSeq(log, 1, Len(log) - 1)", "log",
     "OpenIsClean"),
    ("TurnLifecycle", "reopen skips turn_interrupted",
     "log' = IF IsOpen(log) THEN Append(log, \"interrupt\") ELSE log", "log' = log",
     "NoStaleTurnAfterReopen"),
    ("TurnLifecycle", "manager accepts an item outside a turn",
     '[] k = "item"      -> IsOpen(l)', '[] k = "item"      -> TRUE',
     "ItemsInsideTurns"),
    ("WriterLock", "open ignores the flock",
     "    /\\ holder = None\n    /\\ holder' = p", "    /\\ holder' = p",
     "OneWriter"),
    ("ResumeSnapshot", "snapshot stores the wrong state",
     'Entry("snap", NoVal, Full(log))', 'Entry("snap", NoVal, Empty)',
     "ResumeEqualsFullReplay"),
    ("Fork", "fork forgets blob links",
     "links' = [links EXCEPT ![f] = links[src]]", "links' = links",
     "RefsExist"),
    ("Fork", "fork copies a line whose blob was lost",
     "    /\\ \\A i \\in 2..at : lg[src][i].b # NoBlob => lg[src][i].b \\in links[src]\n", "",
     "RefsExist"),
    ("Fork", "fork allowed inside an open turn",
     "    /\\ ~IsOpen(SubSeq(lg[src], 1, at))\n", "",
     "ForkAtBoundary"),
    ("Subagents", "repair marks every child lost",
     'o |-> IF childLog[c] THEN "interrupted" ELSE "lost"', 'o |-> "lost"',
     "LostMeansNoLog"),
    ("Subagents", "spawn while the child's work is open",
     "    /\\ ~Unfinished(c)\n    /\\ Works(c) < MaxWork",
     "    /\\ Works(c) < MaxWork",
     "OneOpenWork"),
    ("Wiring", "close without joining child threads",
     "    /\\ child = \"none\"\n    /\\ cur' = IF s = cur",
     "    /\\ cur' = IF s = cur",
     "ParentOutlivesChildren"),
    ("Wiring", "switch to the session already open",
     "    /\\ s # cur\n",
     "",
     "SwitchIsTwoSessions"),
    ("Wiring", "continue a committed turn",
     "    /\\ lastEnd[cur] = \"interrupt\"\n",
     "",
     "ContinueLinksInterrupted"),
    ("Subagents", "reopen skips child repair",
     "    /\\ repairing' = TRUE\n    /\\ UNCHANGED <<plog, childLog, thread>>",
     "    /\\ repairing' = FALSE\n    /\\ UNCHANGED <<plog, childLog, thread>>",
     "NoIndeterminate"),
    ("Catalog", "list skips the folder check",
     'Listed == {s \\in Indexed : dir[s] = "live"}', "Listed == Indexed",
     "ListedAreLive"),
    ("Fork", "a setting lists a blob the session lacks",
     "    /\\ b \\in links[s]\n    /\\ lg' = [lg EXCEPT ![s] = Append(@, E(\"set\", b))]",
     "    /\\ lg' = [lg EXCEPT ![s] = Append(@, E(\"set\", b))]",
     "RefsExist"),
    ("MoveSideFiles", "the map is written before every body is a blob",
     "    /\\ ~mapped\n    /\\ blobs = Handles\n    /\\ mapped' = TRUE",
     "    /\\ ~mapped\n    /\\ mapped' = TRUE",
     "Resolvable"),
    ("MoveSideFiles", "the side folder goes before the terminal moved",
     "    /\\ mapped\n    /\\ terminal = \"moved\"\n    /\\ folder = \"present\"",
     "    /\\ mapped\n    /\\ folder = \"present\"",
     "TerminalKept"),
    ("Catalog", "an index refresh for a session never published",
     'Refresh(s) ==\n    /\\ dir[s] = "live"', "Refresh(s) ==\n    /\\ TRUE",
     "IndexNamesPublished"),
    ("Lifecycle", "rename before fsync of line 1",
     'Advance(s, "synced", "renamed")', 'Advance(s, "written", "renamed")',
     "VisibleHasLine1"),
    ("Lifecycle", "ack before fsync of the directory",
     'Advance(s, "renamed", "done")', 'Advance(s, "synced", "done")',
     "AckedIsVisible"),
    ("PromptImages", "the note names an image the store refused",
     'noted |-> {d \\in turn.asked : turn.form[d] = "ref"} \\cup Earlier(turn.s, "ref")',
     'noted |-> turn.asked \\cup Earlier(turn.s, "ref")',
     "NoteNamesBlob"),
    ("PromptImages", "the request is built before its images are saved",
     '    /\\ Saved\n'
     '    /\\ requests\' = Append(requests,\n'
     '         [s |-> turn.s,\n'
     '          asked |-> turn.asked,\n'
     '          sent |-> {d \\in turn.asked : turn.form[d] \\in Forms}\n'
     '                   \\cup Earlier(turn.s, "ref") \\cup Earlier(turn.s, "inline"),\n'
     '          noted |-> {d \\in turn.asked : turn.form[d] = "ref"} \\cup Earlier(turn.s, "ref")])',
     '    /\\ requests\' = Append(requests,\n'
     '         [s |-> turn.s,\n'
     '          asked |-> turn.asked,\n'
     '          sent |-> turn.asked \\cup Earlier(turn.s, "ref") \\cup Earlier(turn.s, "inline"),\n'
     '          noted |-> {d \\in turn.asked : turn.form[d] \\in {"ref", "unsaved"}} \\cup Earlier(turn.s, "ref")])',
     "NoteNamesBlob"),
    ("PromptImages", "the item names blobs it does not list",
     'listed |-> pending[turn.s]])]', 'listed |-> {}])]',
     "RefHasBlob"),
    ("PromptImages", "bytes already stored are not listed again",
     "    /\\ pending' = [pending EXCEPT ![turn.s] = @ \\cup {d}]",
     "    /\\ pending' = [pending EXCEPT ![turn.s] = IF d \\in blobs[turn.s] THEN @ ELSE @ \\cup {d}]",
     "RefHasBlob"),
    ("PromptImages", "a fork hard-links no blobs",
     '    /\\ blobs\' = [blobs EXCEPT !["fork"] =\n'
     '         UNION {log["source"][k].listed : k \\in 1..Len(log["source"])}]',
     '    /\\ blobs\' = [blobs EXCEPT !["fork"] = {}]',
     "RefHasBlob"),
    ("PromptImages", "an import names an image it never saved",
     'form |-> [d \\in Digests |-> IF d \\in asked THEN "unsaved" ELSE "none"],\n'
     '                requested |-> TRUE',
     'form |-> [d \\in Digests |-> IF d \\in asked THEN "ref" ELSE "none"],\n'
     '                requested |-> TRUE',
     "RefHasBlob"),
    # A failed save losing the image, once per place that keeps it, so each
    # mutant fails only its own invariant.
    ("PromptImages", "a request leaves out an image kept inline",
     'sent |-> {d \\in turn.asked : turn.form[d] \\in Forms}',
     'sent |-> {d \\in turn.asked : turn.form[d] = "ref"}',
     "RequestSendsAll"),
    ("PromptImages", "an item leaves out an image kept inline",
     'images |-> [d \\in Digests |-> IF d \\in turn.asked THEN turn.form[d] ELSE "none"]',
     'images |-> [d \\in Digests |-> IF d \\in turn.asked /\\ turn.form[d] = "ref" THEN "ref" ELSE "none"]',
     "ItemKeepsImages"),
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
    return None


def main():
    java = find_java()
    if java is None or not os.path.isfile(JAR):
        print("needs a Java runtime and tla2tools.jar (see check.sh)", file=sys.stderr)
        return 2
    survivors = 0
    # Spec names on the command line run only their mutants.
    wanted = set(sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="session-manager-mutants-") as tmp:
        for index, (spec, desc, old, new, expected) in enumerate(MUTANTS):
            if wanted and spec not in wanted:
                continue
            work = pathlib.Path(tmp) / f"{index:02d}-{spec}"
            work.mkdir()
            text = (HERE / f"{spec}.tla").read_text()
            if old not in text:
                print(f"{spec:15s} {desc:42s} STALE: mutation no longer applies")
                survivors += 1
                continue
            (work / f"{spec}.tla").write_text(text.replace(old, new, 1))
            # A smaller model, when the full one is too large to search per mutant.
            small = HERE / f"{spec}.mutants.cfg"
            shutil.copy(small if small.exists() else HERE / f"{spec}.cfg", work / f"{spec}.cfg")
            run = subprocess.run(
                [java, "-XX:+UseParallelGC", "-cp", JAR, "tlc2.TLC", "-deadlock",
                 "-workers", "auto", "-cleanup", "-metadir", str(work / "states"),
                 "-config", f"{spec}.cfg", f"{spec}.tla"],
                cwd=work, capture_output=True, text=True, timeout=900,
            )
            output = run.stdout + run.stderr
            if (f"Invariant {expected} is violated" in output
                    or f"Action property {expected} is violated" in output):
                print(f"{spec:15s} {desc:42s} caught by {expected}")
            else:
                print(f"{spec:15s} {desc:42s} SURVIVED (expected {expected} to fail)")
                survivors += 1
    print("all mutants caught" if survivors == 0 else f"{survivors} mutant(s) survived")
    return 0 if survivors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
