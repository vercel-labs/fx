------------------------- MODULE PR1073Interactive -------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Sessions
VARIABLES up, cur, next, turn, ended, linked, busy, selected, refusal,
          child, childOf, backend, hint, relaunch
vars == <<up, cur, next, turn, ended, linked, busy, selected, refusal,
          child, childOf, backend, hint, relaunch>>
None == "none"
TypeOK == /\ up \in BOOLEAN /\ cur \in Sessions \cup {None} /\ next \in Sessions \cup {None}
          /\ turn \in [Sessions -> BOOLEAN] /\ ended \in [Sessions -> {None, "commit", "interrupt"}]
          /\ linked \in [Sessions -> {None, "commit", "interrupt"}] /\ busy \subseteq Sessions
          /\ selected \in Sessions \cup {None} /\ refusal \in BOOLEAN /\ child \in BOOLEAN
          /\ childOf \in Sessions \cup {None} /\ backend \in {"v1", "v2"}
          /\ hint \in {None, "v1", "v2"} /\ relaunch \in {None, "v1", "v2"}
Init == /\ up = TRUE /\ cur = None /\ next = None
        /\ turn = [s \in Sessions |-> FALSE] /\ ended = [s \in Sessions |-> None]
        /\ linked = [s \in Sessions |-> None] /\ busy = {} /\ selected = None /\ refusal = FALSE
        /\ child = FALSE /\ childOf = None /\ backend \in {"v1", "v2"} /\ hint = None /\ relaunch = None
ExternalBusy(s) == /\ s # cur /\ s # next /\ busy' = busy \cup {s}
                   /\ UNCHANGED <<up, cur, next, turn, ended, linked, selected, refusal, child, childOf, backend, hint, relaunch>>
ExternalRelease(s) == /\ busy' = busy \ {s}
                      /\ UNCHANGED <<up, cur, next, turn, ended, linked, selected, refusal, child, childOf, backend, hint, relaunch>>
Pick(s) == /\ up /\ next = None /\ selected' = s /\ refusal' = (s \in busy)
           /\ IF s \in busy \/ s = cur THEN UNCHANGED <<cur, next, turn, ended>>
              ELSE /\ IF cur = None THEN cur' = s /\ next' = None ELSE cur' = cur /\ next' = s
                   /\ turn' = [turn EXCEPT ![s] = FALSE]
                   /\ ended' = IF turn[s] THEN [ended EXCEPT ![s] = "interrupt"] ELSE ended
           /\ UNCHANGED <<up, linked, busy, child, childOf, backend, hint, relaunch>>
Begin == /\ up /\ cur # None /\ next = None /\ ~turn[cur]
         /\ turn' = [turn EXCEPT ![cur] = TRUE] /\ linked' = [linked EXCEPT ![cur] = None]
         /\ UNCHANGED <<up, cur, next, ended, busy, selected, refusal, child, childOf, backend, hint, relaunch>>
Continue == /\ up /\ cur # None /\ next = None /\ ~turn[cur] /\ ended[cur] = "interrupt"
            /\ turn' = [turn EXCEPT ![cur] = TRUE] /\ linked' = [linked EXCEPT ![cur] = ended[cur]]
            /\ UNCHANGED <<up, cur, next, ended, busy, selected, refusal, child, childOf, backend, hint, relaunch>>
End(e) == /\ up /\ cur # None /\ turn[cur]
          /\ turn' = [turn EXCEPT ![cur] = FALSE] /\ ended' = [ended EXCEPT ![cur] = e]
          /\ UNCHANGED <<up, cur, next, linked, busy, selected, refusal, child, childOf, backend, hint, relaunch>>
Spawn == /\ up /\ cur # None /\ turn[cur] /\ ~child /\ child' = TRUE /\ childOf' = cur
         /\ UNCHANGED <<up, cur, next, turn, ended, linked, busy, selected, refusal, backend, hint, relaunch>>
Join == /\ child /\ child' = FALSE /\ childOf' = None
        /\ UNCHANGED <<up, cur, next, turn, ended, linked, busy, selected, refusal, backend, hint, relaunch>>
Switch == /\ up /\ next # None /\ ~child /\ cur' = next /\ next' = None
          /\ turn' = [turn EXCEPT ![cur] = FALSE]
          /\ ended' = IF turn[cur] THEN [ended EXCEPT ![cur] = "interrupt"] ELSE ended
          /\ UNCHANGED <<up, linked, busy, selected, refusal, child, childOf, backend, hint, relaunch>>
Exit == /\ up /\ ~child /\ hint' = backend /\ relaunch' = backend
        /\ up' = FALSE /\ cur' = None /\ next' = None /\ turn' = [s \in Sessions |-> FALSE]
        /\ UNCHANGED <<ended, linked, busy, selected, refusal, child, childOf, backend>>
Crash == /\ up /\ up' = FALSE /\ cur' = None /\ next' = None /\ child' = FALSE /\ childOf' = None
         /\ UNCHANGED <<turn, ended, linked, busy, selected, refusal, backend, hint, relaunch>>
Restart == /\ ~up /\ up' = TRUE
           /\ UNCHANGED <<cur, next, turn, ended, linked, busy, selected, refusal, child, childOf, backend, hint, relaunch>>
Next == (\E s \in Sessions : Pick(s) \/ ExternalBusy(s) \/ ExternalRelease(s))
        \/ Begin \/ Continue \/ (\E e \in {"commit", "interrupt"} : End(e))
        \/ Spawn \/ Join \/ Switch \/ Exit \/ Crash \/ Restart \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
SwitchDistinct == next # None => cur # None /\ cur # next
ParentOutlivesChild == child => up /\ cur = childOf
ContinueOnlyInterrupted == \A s \in Sessions : linked[s] \in {None, "interrupt"}
FlagKept == hint \in {None, backend} /\ relaunch \in {None, backend}
NoBusyWriter == cur \notin busy /\ next \notin busy
=============================================================================
