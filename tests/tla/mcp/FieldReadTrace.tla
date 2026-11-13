---- MODULE FieldReadTrace ----
\* Trace wrapper for FieldRead.tla (U01). tests/tla/drivers/mcp/bridge.ts
\* generates TraceObs from the records of one scenario.
\*
\* Mapping from the lab (tests/tla/drivers/mcp/labs/wire_lab.zig, `fields`):
\*   - Each record is one Read of one asked field in one object, which the
\*     real wire.objectFields scanned. `plain`, `escaped` and `other` are what
\*     the scenario wrote, counted by the scenario that built the object;
\*     `flag` is the field's boolean value.
\*   - `engine` is what objectFields found: 0 the field is absent, 1 it found
\*     one member, 2 it refused the object as a duplicate.
\*   - KeyRead comes from the scenario (ObsRawKeyRead): 0 is the engine's
\*     code, which decodes names; 1 is the model of the code before the fix,
\*     and a trace of the fixed code must be rejected by it.
\*   - MaxMembers only bounds the model's own choices, not the trace's.
EXTENDS FieldRead, TraceObs, Integers, Sequences

VARIABLE i

ObsKeyRead == IF ObsRawKeyRead = 1 THEN "raw" ELSE "decoded"

ObsView(n) == CASE n = 0 -> "absent" [] n = 1 -> "value" [] OTHER -> "dup"

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ r.event = "read"
          /\ Read(r.data.plain, r.data.escaped, r.data.other, r.data.flag)
          /\ engineView' = ObsView(r.data.engine)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====
