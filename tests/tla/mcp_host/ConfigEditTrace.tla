---- MODULE ConfigEditTrace ----
\* Trace wrapper for ConfigEdit.tla. trace.ts generates TraceObs from real
\* `fx mcp add`, `remove` and `list --json` runs, each in its own HOME and
\* workspace (tests/tla/drivers/mcp_host/config-edit.test.ts).
\*   init {profile, project}   the two files before the first command, each
\*                             {st, typo, both, big, ent}; ent has every name
\*   add {file, name, class, outcome, same}
\*                             outcome: "added" (Added ...) or "refused"
\*                             (Couldn't add ...); same: the file's bytes
\*                             after are the bytes before
\*   remove {file, name, outcome, same}
\*                             outcome: "removed", "refused" (Couldn't
\*                             remove ...), or "missing" (No MCP server named ...)
\*   list {file, loaded}       the names `fx mcp list --json` shows from the file
\*   tamper {kind, file, name, class}
\*                             the harness edits a file itself, as an editor would:
\*                             typo_appears, typo_fixed, grows, both_appear,
\*                             both_merged, hand, breaks, repairs, deletes
EXTENDS ConfigEdit, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF AddedIsLoaded THEN {} ELSE {"AddedIsLoaded"}) \cup
    (IF RefusedLeavesFile THEN {} ELSE {"RefusedLeavesFile"}) \cup
    (IF NoRewriteOfMisspelled THEN {} ELSE {"NoRewriteOfMisspelled"}) \cup
    (IF OthersKept THEN {} ELSE {"OthersKept"})


Step(rec) ==
    CASE rec.event = "init" ->
            /\ st = [f \in Files |-> rec.data[f].st]
            /\ ent = [f \in Files |-> [n \in Names |-> rec.data[f].ent[n]]]
            /\ typo = rec.data.profile.typo
            /\ both = rec.data.profile.both
            /\ big = rec.data.profile.big
            /\ UNCHANGED vars
      [] rec.event = "add" ->
            /\ Add(rec.data.file, rec.data.name, rec.data.class)
            /\ last' = rec.data.outcome
            /\ same' = rec.data.same
      [] rec.event = "remove" ->
            /\ Remove(rec.data.file, rec.data.name)
            /\ last' = rec.data.outcome
            /\ same' = rec.data.same
      [] rec.event = "list" ->
            /\ LoadedNames(rec.data.file) = rec.data.loaded
            /\ UNCHANGED vars
      [] rec.event = "tamper" ->
            \/ rec.data.kind = "typo_appears" /\ TypoAppears
            \/ rec.data.kind = "typo_fixed" /\ TypoFixed
            \/ rec.data.kind = "grows" /\ Grows
            \/ rec.data.kind = "both_appear" /\ BothAppear
            \/ rec.data.kind = "both_merged" /\ BothMerged
            \/ rec.data.kind = "hand" /\ HandEntry(rec.data.file, rec.data.name, rec.data.class)
            \/ rec.data.kind = "breaks" /\ Breaks(rec.data.file)
            \/ rec.data.kind = "repairs" /\ Repairs(rec.data.file)
            \/ rec.data.kind = "deletes" /\ Deletes(rec.data.file)
      [] OTHER -> FALSE

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ i' = i + 1
    /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
