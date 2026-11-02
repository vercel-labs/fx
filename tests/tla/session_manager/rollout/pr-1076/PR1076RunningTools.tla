------------------------ MODULE PR1076RunningTools -------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Tools
Causes == {"NoSpaceLeft", "AccessDenied", "ReadOnlyFileSystem", "FileTooBig", "Io"}
VARIABLES up, recovered, calls, started, completed, results, firstCause, fault, reported
vars == <<up, recovered, calls, started, completed, results, firstCause, fault, reported>>
TypeOK == /\ up \in BOOLEAN /\ recovered \in BOOLEAN /\ calls \subseteq Tools
          /\ started \subseteq Tools /\ completed \subseteq Tools
          /\ results \in [Tools -> {"none", "real", "partial"}]
          /\ firstCause \in Causes \cup {"none"} /\ fault \in Causes \cup {"none"}
          /\ reported \in Causes \cup {"none"}
Init == /\ up = TRUE /\ recovered = FALSE /\ calls = {} /\ started = {} /\ completed = {}
        /\ results = [t \in Tools |-> "none"] /\ firstCause = "none" /\ fault = "none" /\ reported = "none"
SaveCall(t) == /\ up /\ fault = "none" /\ ~recovered /\ calls' = calls \cup {t}
               /\ UNCHANGED <<up, recovered, started, completed, results, firstCause, fault, reported>>
Execute(t) == /\ up /\ fault = "none" /\ t \in calls /\ t \notin started /\ ~recovered
              /\ started' = started \cup {t}
              /\ UNCHANGED <<up, recovered, calls, completed, results, firstCause, fault, reported>>
Finish(t) == /\ up /\ fault = "none" /\ t \in started /\ results[t] = "none" /\ ~recovered
             /\ completed' = completed \cup {t} /\ results' = [results EXCEPT ![t] = "real"]
             /\ UNCHANGED <<up, recovered, calls, started, firstCause, fault, reported>>
Fail(e) == /\ up /\ fault = "none" /\ firstCause' = e /\ fault' = e
           /\ UNCHANGED <<up, recovered, calls, started, completed, results, reported>>
LaterFailure(e) == /\ up /\ fault # "none" /\ fault' = firstCause
                  /\ reported' = firstCause
                  /\ UNCHANGED <<up, recovered, calls, started, completed, results, firstCause>>
Crash == /\ up /\ up' = FALSE
         /\ UNCHANGED <<recovered, calls, started, completed, results, firstCause, fault, reported>>
Resume == /\ ~up /\ up' = TRUE /\ recovered' = TRUE
          /\ results' = [t \in Tools |-> IF t \in calls /\ results[t] = "none" THEN "partial" ELSE results[t]]
          /\ UNCHANGED <<calls, started, completed, firstCause, fault, reported>>
Next == (\E t \in Tools : SaveCall(t) \/ Execute(t) \/ Finish(t))
        \/ (\E e \in Causes : Fail(e) \/ LaterFailure(e)) \/ Crash \/ Resume \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
CallBeforeExecution == started \subseteq calls
RealResultsKept == \A t \in completed : results[t] = "real"
RecoveryAnswersEveryCall == recovered => \A t \in calls : results[t] # "none"
FirstCauseSticky == fault = firstCause /\ reported \in {"none", firstCause}
=============================================================================
