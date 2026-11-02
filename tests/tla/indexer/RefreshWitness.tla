---------------------------- MODULE RefreshWitness ----------------------------
\* Each invariant claims a reuse path cannot happen. TLC's counterexample is
\* then the shortest trace that exercises it, which the real replay runs.
EXTENDS Refresh
Before(a, b) == \E i, j \in 1..Len(history) : i < j /\ history[i] \in a /\ history[j] = b
NoReuse == ~Before({"Begin"}, "Reuse")
NoReuseAfterEdit == ~Before({"Edit:a.txt", "Edit:b.txt"}, "Reuse")
\* Real files have only times, so an ignore change counts once a Tick passes;
\* b.txt exists first so the reused snapshot must reflect the new rule.
NoReuseAfterIgnore == ~\E i, k, m, j \in 1..Len(history) :
    /\ i < k /\ k < m /\ m < j
    /\ history[i] = "Edit:b.txt" /\ history[k] = "ChangeIgnore"
    /\ history[m] = "Tick" /\ history[j] = "Reuse"
\* A change after a reuse: the real code must notice it at the next check.
NoEditAfterReuse == ~\E i, j \in 1..Len(history) :
    i < j /\ history[i] = "Reuse" /\ history[j] \in {"Edit:a.txt", "Edit:b.txt"}
NoIgnoreChangeAfterReuse == ~\E i, k, j \in 1..Len(history) :
    /\ i < k /\ k < j
    /\ history[i] = "Edit:b.txt" /\ history[k] = "Reuse"
    /\ history[j] = "ChangeIgnore"
=============================================================================
