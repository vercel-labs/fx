---- MODULE ConnectTrace ----
\* Trace wrapper for Connect.tla. The driver
\* (tests/tla/drivers/mcp_host/connect.test.ts) reads the connect events of real
\* `fx ask` runs against many HTTP MCP servers, one trace per socket, and
\* has TLC check each one. ObsStd is TRUE for a trace that shows std's retry.
\*   start {}                     a socket was opened and connect was called
\*   intr {}                      a signal interrupted the connect or the wait
\*   reissue {}                   connect was called again on the same socket
\*                                (std's loop; the kernel answered ISCONN)
\*   done {result}                the connect ended: "ok", "refused", "other" (any
\*                                other failure), "canceled", or "unexpected"
\*                                (std's error.Unexpected after its reissue)
\* The kernel finishing and a cancel request are not seen by fx, so TLC may
\* place them anywhere between two records.
EXTENDS Connect, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF NoFalseFailure THEN {} ELSE {"NoFalseFailure"}) \cup
    (IF NoFalseSuccess THEN {} ELSE {"NoFalseSuccess"}) \cup
    (IF CancelWins THEN {} ELSE {"CancelWins"}) \cup
    (IF NoReissue THEN {} ELSE {"NoReissue"}) \cup
    (IF CanceledNeedsCancel THEN {} ELSE {"CanceledNeedsCancel"}) \cup
    (IF ReturnsBlocking THEN {} ELSE {"ReturnsBlocking"})

Finished(result) ==
    \/ /\ result = "ok"
       /\ \/ StdReturn
          \/ FixedPass
       /\ res' = "ok"
    \/ /\ result = "canceled"
       /\ \/ StdCancelled
          \/ FixedPass
       /\ res' = "canceled"
    \/ /\ result \in {"refused", "other"}
       /\ \/ StdReturn
          \/ FixedPass
       /\ res' = "fail"
    \* std's error.Unexpected comes right after the reissue: nothing changes.
    \/ /\ result = "unexpected"
       /\ th = "done" /\ res = "fail"
       /\ UNCHANGED vars

Step(rec) ==
    CASE rec.event = "start" -> Start
      [] rec.event = "intr" ->
            /\ th \in {"in_connect", "waiting"}
            /\ UNCHANGED vars
      [] rec.event = "reissue" -> StdRetry
      [] rec.event = "done" -> Finished(rec.data.result)
      [] OTHER -> FALSE

\* What fx cannot see.
Hidden == KernelDone \/ Cancel

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ i' = i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
