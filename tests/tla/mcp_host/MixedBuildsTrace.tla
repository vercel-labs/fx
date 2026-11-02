---- MODULE MixedBuildsTrace ----
\* Trace wrapper for MixedBuilds.tla. tests/tla/drivers/mcp_host/mixed-builds.test.ts
\* makes TraceObs from real `fx mcp` runs against a scratch HOME, with an older
\* build's writes to credentials-v2.json played by the harness, as that build
\* writes them:
\*   run {cmd}      a command of this build: "get" (fx mcp list: a host
\*                  starts and reads its store), "signin" (fx mcp login) or
\*                  "logout" (fx mcp logout)
\*   older {op}     the older build: "save" (it refreshed and saved the login)
\*                  or "remove" (its login ended, and it removed it)
\*   observe {v2kind, v2, v3}  the files after it: v2kind "absent", "v1" or
\*                  "v2", and whether each document holds the server's login
\* Between a run record and the next observation, what that command may do
\* is hidden steps; an observation ends the command.
EXTENDS MixedBuilds, TraceObs, Sequences

VARIABLES i, bad, cmd

Viol ==
    (IF NoLoginErasedByOlder THEN {} ELSE {"NoLoginErasedByOlder"}) \cup
    (IF NoLoginEndedByOlder THEN {} ELSE {"NoLoginEndedByOlder"}) \cup
    (IF OlderLoginNotTaken THEN {} ELSE {"OlderLoginNotTaken"})

Observed(d) ==
    /\ v2kind = d.v2kind
    /\ (v2 # None) = d.v2
    /\ (v3 # None) = d.v3

Step(rec) ==
    CASE rec.event = "older" /\ rec.data.op = "save" -> OlderRefresh /\ older' # None /\ UNCHANGED cmd
      [] rec.event = "older" /\ rec.data.op = "remove" -> OlderEnds /\ UNCHANGED cmd
      [] rec.event = "run" -> UNCHANGED vars /\ cmd' = rec.data.cmd
      [] rec.event = "observe" -> Observed(rec.data) /\ UNCHANGED vars /\ cmd' = ""
      [] OTHER -> FALSE

\* What the current command may do: every command starts a host, which reads
\* the store, then signs in or out.
Hidden ==
    /\ cmd # ""
    /\ \/ ThisGet
       \/ (cmd = "signin" /\ ThisSignIn)
       \/ (cmd = "logout" /\ ThisLogout)
    /\ UNCHANGED cmd

TraceInit == Init /\ i = 0 /\ bad = Viol /\ cmd = ""

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
