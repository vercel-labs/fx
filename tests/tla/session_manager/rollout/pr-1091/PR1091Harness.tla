--------------------------- MODULE PR1091Harness ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT MaxCases
Hosts == {"ask-id", "ask-last", "app-id", "app-continue", "acp-load", "acp-resume"}
Endings == {"committed", "cancelled", "mid-reply", "mid-tool"}
Faults == {"none", "tail", "corrupt", "missing-blob", "readonly", "diskfull", "busy"}
Grid == Hosts \X Endings \X Faults
NoneCase == <<>>
VARIABLES requested, server, pane, running, observed, chosen, checked, count
vars == <<requested, server, pane, running, observed, chosen, checked, count>>
Expected == IF requested = "v2" THEN "v2" ELSE "v1"
TypeOK == /\ requested \in {"unset", "v2"} /\ server \in {"unset", "v2"}
          /\ pane \in {"unset", "v2"} /\ running \in BOOLEAN /\ observed \in {"none", "v1", "v2"}
          /\ chosen \in Grid \cup {NoneCase} /\ checked \subseteq Grid /\ count \in 0..MaxCases
Init == /\ requested \in {"unset", "v2"} /\ server \in {"unset", "v2"}
        /\ pane = "unset" /\ running = FALSE /\ observed = "none"
        /\ chosen = NoneCase /\ checked = {} /\ count = 0
SpawnPane == /\ ~running /\ pane' = requested /\ running' = TRUE
             /\ UNCHANGED <<requested, server, observed, chosen, checked, count>>
ChooseCase(c) == /\ running /\ chosen = NoneCase /\ count < MaxCases /\ c \notin checked
                 /\ chosen' = c
                 /\ UNCHANGED <<requested, server, pane, running, observed, checked, count>>
InspectBackend == /\ running /\ chosen # NoneCase
                  /\ observed' = IF pane = "v2" THEN "v2" ELSE "v1"
                  /\ UNCHANGED <<requested, server, pane, running, chosen, checked, count>>
RecordVerdict == /\ running /\ chosen # NoneCase /\ observed = Expected
                 /\ checked' = checked \cup {chosen} /\ chosen' = NoneCase /\ count' = count + 1
                 /\ UNCHANGED <<requested, server, pane, running, observed>>
Next == SpawnPane \/ (\E c \in Grid : ChooseCase(c)) \/ InspectBackend \/ RecordVerdict \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
PaneGetsCallerEnvironment == running => pane = requested
EvidenceNamesCorrectBackend == observed # "none" => observed = Expected
NoDuplicateCoverage == count = Cardinality(checked)
OnlyDefinedGridCells == checked \subseteq Grid
=============================================================================
