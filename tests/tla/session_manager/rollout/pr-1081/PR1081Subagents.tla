-------------------------- MODULE PR1081Subagents --------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Children, MaxWork
Terminal == {"none", "ok", "failed", "cancelled", "interrupted", "lost"}
VARIABLES up, parentOpen, stage, work, hasLog, history, threads, backend, childBackend, listed
vars == <<up, parentOpen, stage, work, hasLog, history, threads, backend, childBackend, listed>>
TypeOK == /\ up \in BOOLEAN /\ parentOpen \in BOOLEAN
          /\ stage \in [Children -> Terminal \cup {"spawned", "running"}]
          /\ work \in [Children -> 0..MaxWork] /\ hasLog \in [Children -> BOOLEAN]
          /\ history \in [Children -> 0..MaxWork] /\ threads \subseteq Children
          /\ backend \in {"v1", "v2"} /\ childBackend \in [Children -> {"v1", "v2"}]
          /\ listed \subseteq Children
Init == /\ up = TRUE /\ parentOpen = TRUE /\ stage = [c \in Children |-> "none"]
        /\ work = [c \in Children |-> 0] /\ hasLog = [c \in Children |-> FALSE]
        /\ history = [c \in Children |-> 0] /\ threads = {}
        /\ backend \in {"v1", "v2"} /\ childBackend = [c \in Children |-> backend] /\ listed = {}
Spawn(c) == /\ up /\ parentOpen /\ stage[c] \in Terminal /\ work[c] < MaxWork
            /\ work' = [work EXCEPT ![c] = @ + 1] /\ stage' = [stage EXCEPT ![c] = "spawned"]
            /\ childBackend' = [childBackend EXCEPT ![c] = backend]
            /\ UNCHANGED <<up, parentOpen, hasLog, history, threads, backend, listed>>
BeginWork(c) == /\ up /\ parentOpen /\ stage[c] = "spawned"
                /\ stage' = [stage EXCEPT ![c] = "running"] /\ hasLog' = [hasLog EXCEPT ![c] = TRUE]
                /\ history' = [history EXCEPT ![c] = @ + 1] /\ threads' = threads \cup {c}
                /\ UNCHANGED <<up, parentOpen, work, backend, childBackend, listed>>
Finish(c,e) == /\ up /\ parentOpen /\ c \in threads /\ stage[c] = "running"
               /\ stage' = [stage EXCEPT ![c] = e] /\ threads' = threads \ {c}
               /\ UNCHANGED <<up, parentOpen, work, hasLog, history, backend, childBackend, listed>>
Crash == /\ up /\ up' = FALSE /\ parentOpen' = FALSE /\ threads' = {}
         /\ UNCHANGED <<stage, work, hasLog, history, backend, childBackend, listed>>
Reopen == /\ ~up /\ up' = TRUE /\ parentOpen' = TRUE
          /\ stage' = [c \in Children |-> IF stage[c] \in {"spawned", "running"}
                      THEN IF hasLog[c] THEN "interrupted" ELSE "lost" ELSE stage[c]]
          /\ UNCHANGED <<work, hasLog, history, threads, backend, childBackend, listed>>
Close == /\ up /\ parentOpen /\ threads = {} /\ parentOpen' = FALSE
         /\ UNCHANGED <<up, stage, work, hasLog, history, threads, backend, childBackend, listed>>
List == /\ listed' = {}
        /\ UNCHANGED <<up, parentOpen, stage, work, hasLog, history, threads, backend, childBackend>>
Next == (\E c \in Children : Spawn(c) \/ BeginWork(c) \/ (\E e \in {"ok", "failed", "cancelled"} : Finish(c,e)))
        \/ Crash \/ Reopen \/ Close \/ List \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
ParentOutlivesThreads == threads # {} => up /\ parentOpen
OneBackend == \A c \in Children : childBackend[c] = backend
LostOnlyWithoutLog == \A c \in Children : stage[c] = "lost" => ~hasLog[c]
HistoryAccounted == \A c \in Children : history[c] <= work[c]
ChildrenHidden == listed = {}
=============================================================================
