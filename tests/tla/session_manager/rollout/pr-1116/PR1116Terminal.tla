-------------------------- MODULE PR1116Terminal ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Sessions
VARIABLES appUp, live, folders, running, known, age, cleaned
vars == <<appUp, live, folders, running, known, age, cleaned>>
TypeOK == /\ appUp \in BOOLEAN /\ live \subseteq Sessions /\ folders \subseteq Sessions
          /\ running \subseteq Sessions /\ known \subseteq Sessions
          /\ age \in [Sessions -> 0..2] /\ cleaned \subseteq Sessions
Init == /\ appUp = TRUE /\ live = Sessions /\ folders = {} /\ running = {} /\ known = {}
        /\ age = [s \in Sessions |-> 0] /\ cleaned = {}
Start(s) == /\ appUp /\ s \in live /\ s \notin folders
            /\ folders' = folders \cup {s} /\ running' = running \cup {s} /\ known' = known \cup {s}
            /\ UNCHANGED <<appUp, live, age, cleaned>>
Stop(s) == /\ appUp /\ s \in known /\ s \in live /\ running' = running \ {s}
           /\ UNCHANGED <<appUp, live, folders, known, age, cleaned>>
Crash == /\ appUp /\ appUp' = FALSE /\ known' = {}
         /\ UNCHANGED <<live, folders, running, age, cleaned>>
Resume == /\ ~appUp /\ appUp' = TRUE /\ known' = folders \cap live
          /\ UNCHANGED <<live, folders, running, age, cleaned>>
DeleteSession(s) == /\ s \in live /\ live' = live \ {s} /\ known' = known \ {s}
                    /\ UNCHANGED <<appUp, folders, running, age, cleaned>>
Age(s) == /\ s \notin live /\ age[s] < 2 /\ age' = [age EXCEPT ![s] = @ + 1]
          /\ UNCHANGED <<appUp, live, folders, running, known, cleaned>>
Doctor(s) == /\ s \notin live /\ s \in folders /\ age[s] = 2
             /\ folders' = folders \ {s} /\ cleaned' = cleaned \cup {s}
             /\ UNCHANGED <<appUp, live, running, known, age>>
Next == (\E s \in Sessions : Start(s) \/ Stop(s) \/ DeleteSession(s) \/ Age(s) \/ Doctor(s))
        \/ Crash \/ Resume \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
LiveTerminalRecoverable == running \cap live \subseteq folders
KnownStateHasFolder == known \subseteq folders \cap live
DoctorPreservesLive == cleaned \cap live = {}
=============================================================================
