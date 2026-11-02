---------------------------- MODULE Subagents ----------------------------
(***************************************************************************)
(* Step: L2 children.                                                      *)
(*                                                                         *)
(* The parent log records child_spawned (durable) before the child's work *)
(* starts. A child's first turn creates its own log; a persistent child's *)
(* later work runs in that same log. The child thread appends             *)
(* child_finished (ok or failed), or the parent cancels the work          *)
(* (cancelled). A crash can land between any two steps. On parent reopen, *)
(* the manager closes every unfinished work item: `lost` if the child has *)
(* no log, `interrupted` if it has one.                                    *)
(*                                                                         *)
(* A child has at most one unfinished work item (D22); its later work     *)
(* items are new spawn/finish pairs with the next work number. fx's       *)
(* `data` on these lines is opaque to the manager and not modeled.        *)
(*                                                                         *)
(* Design: system-design.md kinds table, "Reliability And Recovery" and   *)
(* D22.                                                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Children, MaxWork

VARIABLES
    plog,       \* parent log: a sequence of [k, c, w, o]
    childLog,   \* [Children -> BOOLEAN]: {c}/log.jsonl exists
    thread,     \* [Children -> {"none", "starting", "running"}], in memory
    up,         \* the fx process is running
    repairing   \* reopen repair is in progress

vars == <<plog, childLog, thread, up, repairing>>

Outcomes == {"ok", "failed", "cancelled", "interrupted", "lost"}

Count(s, k, c) == Cardinality({i \in 1..Len(s) : s[i].k = k /\ s[i].c = c})
Works(c) == Count(plog, "spawned", c)
Unfinished(c) == Works(c) > Count(plog, "finished", c)
Spawned(c) == Works(c) > 0

TypeOK ==
    /\ \A i \in 1..Len(plog) :
          /\ plog[i].k \in {"spawned", "finished"}
          /\ plog[i].c \in Children
          /\ plog[i].w \in 1..MaxWork
          /\ plog[i].o \in Outcomes \cup {"none"}
    /\ childLog \in [Children -> BOOLEAN]
    /\ thread \in [Children -> {"none", "starting", "running"}]
    /\ up \in BOOLEAN
    /\ repairing \in BOOLEAN

Init ==
    /\ plog = <<>>
    /\ childLog = [c \in Children |-> FALSE]
    /\ thread = [c \in Children |-> "none"]
    /\ up = TRUE
    /\ repairing = FALSE

Normal == up /\ ~repairing

\* 1. The parent appends child_spawned (fsynced), then starts the thread.
\*    Refused while the child still has unfinished work.
Spawn(c) ==
    /\ Normal
    /\ ~Unfinished(c)
    /\ Works(c) < MaxWork
    /\ plog' = Append(plog, [k |-> "spawned", c |-> c, w |-> Works(c) + 1, o |-> "none"])
    /\ thread' = [thread EXCEPT ![c] = "starting"]
    /\ UNCHANGED <<childLog, up, repairing>>

\* 2. The child's work starts a turn; the first one publishes its log.
ChildStart(c) ==
    /\ Normal
    /\ thread[c] = "starting"
    /\ childLog' = [childLog EXCEPT ![c] = TRUE]
    /\ thread' = [thread EXCEPT ![c] = "running"]
    /\ UNCHANGED <<plog, up, repairing>>

\* 3. The child finishes and appends child_finished to the parent.
ChildFinish(c) ==
    /\ Normal
    /\ thread[c] = "running"
    /\ \E o \in {"ok", "failed"} :
          plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c), o |-> o])
    /\ thread' = [thread EXCEPT ![c] = "none"]
    /\ UNCHANGED <<childLog, up, repairing>>

\* 3'. The parent cancels the child's unfinished work and stops its thread.
Cancel(c) ==
    /\ Normal
    /\ thread[c] \in {"starting", "running"}
    /\ plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c), o |-> "cancelled"])
    /\ thread' = [thread EXCEPT ![c] = "none"]
    /\ UNCHANGED <<childLog, up, repairing>>

\* The process dies anywhere. Durable lines stay; threads are gone.
Crash ==
    /\ up
    /\ up' = FALSE
    /\ thread' = [c \in Children |-> "none"]
    /\ repairing' = FALSE
    /\ UNCHANGED <<plog, childLog>>

\* Parent reopen: repair runs before any normal work.
Reopen ==
    /\ ~up
    /\ up' = TRUE
    /\ repairing' = TRUE
    /\ UNCHANGED <<plog, childLog, thread>>

RepairChild(c) ==
    /\ up
    /\ repairing
    /\ Unfinished(c)
    /\ plog' = Append(plog, [k |-> "finished", c |-> c, w |-> Works(c),
                             o |-> IF childLog[c] THEN "interrupted" ELSE "lost"])
    /\ UNCHANGED <<childLog, thread, up, repairing>>

RepairDone ==
    /\ up
    /\ repairing
    /\ \A c \in Children : ~Unfinished(c)
    /\ repairing' = FALSE
    /\ UNCHANGED <<plog, childLog, thread, up>>

Next ==
    \/ \E c \in Children :
          \/ Spawn(c)
          \/ ChildStart(c)
          \/ ChildFinish(c)
          \/ Cancel(c)
          \/ RepairChild(c)
    \/ Crash
    \/ Reopen
    \/ RepairDone

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A child has at most one unfinished work item.
OneOpenWork ==
    \A c \in Children :
        Count(plog, "finished", c) <= Works(c) /\ Works(c) <= Count(plog, "finished", c) + 1

\* Every child_finished closes that child's newest work item, which was
\* unfinished until then: no finish before its spawn, none twice.
FinishClosesOpenWork ==
    \A i \in 1..Len(plog) :
        plog[i].k = "finished" =>
            LET p == SubSeq(plog, 1, i - 1) IN
                /\ Count(p, "spawned", plog[i].c) = Count(p, "finished", plog[i].c) + 1
                /\ plog[i].w = Count(p, "spawned", plog[i].c)

\* A child log never exists without a spawn line in the parent.
NoOrphanChild == \A c \in Children : childLog[c] => Spawned(c)

\* `lost` is recorded only when the child really has no log at that moment.
\* An action property: a persistent child marked lost for one work item may
\* create its log with a later one.
LostMeansNoLog ==
    [][\A i \in (Len(plog) + 1)..Len(plog') :
          (plog'[i].k = "finished" /\ plog'[i].o = "lost") => ~childLog[plog'[i].c]]_vars

\* Outside repair, every unfinished work item has a live thread: no child
\* is ever left in an unknown state.
NoIndeterminate ==
    Normal => \A c \in Children :
        Unfinished(c) => thread[c] \in {"starting", "running"}
=============================================================================
