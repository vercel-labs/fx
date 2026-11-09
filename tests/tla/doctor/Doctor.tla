---------------------------- MODULE Doctor ----------------------------
(***************************************************************************)
(* fx doctor's network checks and their one deadline.                      *)
(*                                                                         *)
(* Probes are tasks in the doctor process (the provider catalog request).  *)
(* A probe writes its result into its own slot in two steps, so another    *)
(* thread can see a half-written slot, and then sets the slot's done flag, *)
(* which ends the task. A probe that is cancelled ends too, with a result  *)
(* that says so.                                                           *)
(*                                                                         *)
(* Children are processes (one `fx mcp show NAME --json` per MCP server,   *)
(* and `gh auth status`). A child writes its status to its own pipe in two *)
(* steps and then exits. A child may start a process of its own in its     *)
(* group, its grandchild, which holds the child's pipe open while it runs, *)
(* and a process that leaves the group, which may also hold the pipe. One  *)
(* waiter task per child reads the pipe to its end, or until it is         *)
(* cancelled, then reaps the child and kills what is left in its group.    *)
(*                                                                         *)
(* Any probe, child, grandchild, or process that left the group can hang  *)
(* at any step: their steps have no fairness, except that a cancelled      *)
(* probe ends. One timer fires at the deadline. The main thread stops      *)
(* waiting when everything is done or the timer fires, notes which probes  *)
(* finished in time, cancels the others, and kills every child whose       *)
(* waiter is not done. After a reap grace it cancels the waiters still     *)
(* blocked, joins every probe and waiter, reports once, and exits.         *)
(*                                                                         *)
(* UseFlag:      a slot counts only when its probe finished in time, and a *)
(*               child's output only when it exited on its own; otherwise  *)
(*               the main thread takes whatever the slot or pipe holds.    *)
(* UseDeadline:  the main thread stops waiting when the timer fires;       *)
(*               otherwise only when every probe and child is done.        *)
(* UseKill:      the main thread kills every child whose waiter is not     *)
(*               done.                                                     *)
(* UseGroupKill: each child runs in its own process group, and each kill,  *)
(*               also the waiter's after the reap, reaches the whole       *)
(*               group, grandchild included; otherwise only the child.     *)
(* UseCancel:    the main thread cancels a probe that did not finish in    *)
(*               time, and after the grace each waiter still blocked.      *)
(* UseJoin:      the main thread reports only after every probe and every  *)
(*               waiter has ended.                                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Probes, Children, Deadline, UseFlag, UseDeadline, UseKill, UseGroupKill, UseCancel, UseJoin

VARIABLES slot, done, cancel, intime, out, child, grand, held, waiter, unblocked, killed,
          clock, fired, graced, main, report, seen

vars == <<slot, done, cancel, intime, out, child, grand, held, waiter, unblocked, killed,
          clock, fired, graced, main, report, seen>>

Parts == {"empty", "partial", "full"}
Checks == Probes \cup Children

Init ==
    /\ slot = [p \in Probes |-> "empty"]
    /\ done = [p \in Probes |-> FALSE]
    /\ cancel = [p \in Probes |-> FALSE]
    /\ intime = [p \in Probes |-> FALSE]
    /\ out = [c \in Children |-> "empty"]
    /\ child = [c \in Children |-> "running"]
    /\ grand = [c \in Children |-> "none"]
    /\ held = [c \in Children |-> "none"]
    /\ waiter = [c \in Children |-> "reading"]
    /\ unblocked = [c \in Children |-> FALSE]
    /\ killed = [c \in Children |-> FALSE]
    /\ clock = 0
    /\ fired = FALSE
    /\ graced = FALSE
    /\ main = "waiting"
    /\ report = [x \in Checks |-> "none"]
    /\ seen = [x \in Checks |-> "empty"]

\* ---- probe tasks ----

WritePart(p) ==
    /\ ~done[p]
    /\ slot[p] = "empty"
    /\ slot' = [slot EXCEPT ![p] = "partial"]
    /\ UNCHANGED <<done, cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

WriteRest(p) ==
    /\ ~done[p]
    /\ slot[p] = "partial"
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ UNCHANGED <<done, cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

Publish(p) ==
    /\ slot[p] = "full"
    /\ ~done[p]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<slot, cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

\* A cancelled probe writes a result that says so, sets its flag, and ends.
EndCancelled(p) ==
    /\ cancel[p]
    /\ ~done[p]
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

\* ---- child processes and what they start ----

ChildWritePart(c) ==
    /\ child[c] = "running"
    /\ out[c] = "empty"
    /\ out' = [out EXCEPT ![c] = "partial"]
    /\ UNCHANGED <<slot, done, cancel, intime, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

ChildWriteRest(c) ==
    /\ child[c] = "running"
    /\ out[c] = "partial"
    /\ out' = [out EXCEPT ![c] = "full"]
    /\ UNCHANGED <<slot, done, cancel, intime, child, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

ChildExit(c) ==
    /\ child[c] = "running"
    /\ out[c] = "full"
    /\ child' = [child EXCEPT ![c] = "exited"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, grand, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

\* The child starts a process of its own in its group, which inherits the
\* child's pipe.
GrandStart(c) ==
    /\ child[c] = "running"
    /\ grand[c] = "none"
    /\ grand' = [grand EXCEPT ![c] = "running"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

GrandExit(c) ==
    /\ grand[c] = "running"
    /\ grand' = [grand EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, held, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

\* The child starts a process that leaves its group, as setsid does, and keeps
\* the child's pipe. No kill of the group reaches it, so doctor does not
\* promise to end it, only not to wait on it.
LeaveStart(c) ==
    /\ child[c] = "running"
    /\ held[c] = "none"
    /\ held' = [held EXCEPT ![c] = "holding"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

LeaveExit(c) ==
    /\ held[c] = "holding"
    /\ held' = [held EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, waiter, unblocked, killed, clock, fired, graced, main, report, seen>>

\* No process holds the child's pipe, so its waiter reads to the end.
PipeClosed(c) == child[c] # "running" /\ grand[c] # "running" /\ held[c] # "holding"

\* The waiter reads to the end of the pipe, or stops when cancelled, then
\* reaps the child, which has ended, and kills what is left in its group.
WaiterEnd(c) ==
    /\ waiter[c] = "reading"
    /\ child[c] \in {"exited", "killed"}
    /\ PipeClosed(c) \/ unblocked[c]
    /\ child' = [child EXCEPT ![c] = "reaped"]
    /\ grand' = IF UseGroupKill /\ grand[c] = "running"
                THEN [grand EXCEPT ![c] = "gone"]
                ELSE grand
    /\ waiter' = [waiter EXCEPT ![c] = "done"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, held, unblocked, killed, clock, fired, graced, main, report, seen>>

\* ---- the timer ----

Tick ==
    /\ clock < Deadline
    /\ clock' = clock + 1
    /\ fired' = (clock + 1 = Deadline)
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, held, waiter, unblocked, killed, graced, main, report, seen>>

\* ---- the main thread ----

AllDone ==
    /\ \A p \in Probes : done[p]
    /\ \A c \in Children : waiter[c] = "done"

\* Stop waiting: everything is done, or the timer fired. Note which probes
\* finished in time and cancel the others. Kill each child whose waiter is
\* not done, and with group kills its grandchild too.
StopWaiting ==
    /\ main = "waiting"
    /\ IF UseDeadline THEN fired \/ AllDone ELSE AllDone
    /\ intime' = done
    /\ cancel' = IF UseCancel THEN [p \in Probes |-> ~done[p]] ELSE cancel
    /\ child' = IF UseKill
                THEN [c \in Children |-> IF child[c] = "running" THEN "killed" ELSE child[c]]
                ELSE child
    /\ grand' = IF UseKill /\ UseGroupKill
                THEN [c \in Children |-> IF waiter[c] # "done" /\ grand[c] = "running" THEN "gone" ELSE grand[c]]
                ELSE grand
    /\ killed' = IF UseKill
                 THEN [c \in Children |-> killed[c] \/ waiter[c] # "done"]
                 ELSE killed
    /\ main' = "reaping"
    /\ UNCHANGED <<slot, done, out, held, waiter, unblocked, clock, fired, graced, report, seen>>

\* The reap grace ends.
GraceEnds ==
    /\ main = "reaping"
    /\ ~graced
    /\ graced' = TRUE
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, main, report, seen>>

\* After the grace, or once every waiter is done, cancel the waiters still
\* reading.
CancelWaiters ==
    /\ main = "reaping"
    /\ graced \/ \A c \in Children : waiter[c] = "done"
    /\ unblocked' = IF UseCancel THEN [c \in Children |-> waiter[c] = "reading"] ELSE unblocked
    /\ main' = "joining"
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, held, waiter, killed, clock, fired, graced, report, seen>>

ProbeFinished(p) == IF UseFlag THEN intime[p] ELSE slot[p] # "empty"

ChildFinished(c) ==
    IF UseFlag THEN waiter[c] = "done" /\ ~killed[c] ELSE out[c] # "empty"

\* Join every probe and waiter, read every slot and pipe once, report, and
\* exit.
MainReport ==
    /\ main = "joining"
    /\ UseJoin => AllDone
    /\ main' = "reported"
    /\ report' = [x \in Checks |->
                    IF x \in Probes
                    THEN IF ProbeFinished(x) THEN "result" ELSE "timed_out"
                    ELSE IF ChildFinished(x) THEN "result" ELSE "timed_out"]
    /\ seen' = [x \in Checks |-> IF x \in Probes THEN slot[x] ELSE out[x]]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, held, waiter, unblocked, killed, clock, fired, graced>>

ProbeStep == \E p \in Probes : WritePart(p) \/ WriteRest(p) \/ Publish(p) \/ EndCancelled(p)
ChildStep == \E c \in Children :
    \/ ChildWritePart(c) \/ ChildWriteRest(c) \/ ChildExit(c)
    \/ GrandStart(c) \/ GrandExit(c) \/ LeaveStart(c) \/ LeaveExit(c)
    \/ WaiterEnd(c)
MainStep == StopWaiting \/ GraceEnds \/ CancelWaiters \/ MainReport

Next == ProbeStep \/ ChildStep \/ Tick \/ MainStep

\* Probes, children, grandchildren, and processes that left the group get no
\* fairness, so any of them can hang forever. A cancelled probe ends, and a
\* waiter that can end does.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A p \in Probes : WF_vars(EndCancelled(p))
    /\ \A c \in Children : WF_vars(WaiterEnd(c))
    /\ WF_vars(Tick)
    /\ WF_vars(StopWaiting)
    /\ WF_vars(GraceEnds)
    /\ WF_vars(CancelWaiters)
    /\ WF_vars(MainReport)

TypeOK ==
    /\ slot \in [Probes -> Parts]
    /\ done \in [Probes -> BOOLEAN]
    /\ cancel \in [Probes -> BOOLEAN]
    /\ intime \in [Probes -> BOOLEAN]
    /\ out \in [Children -> Parts]
    /\ child \in [Children -> {"running", "exited", "killed", "reaped"}]
    /\ grand \in [Children -> {"none", "running", "gone"}]
    /\ held \in [Children -> {"none", "holding", "gone"}]
    /\ waiter \in [Children -> {"reading", "done"}]
    /\ unblocked \in [Children -> BOOLEAN]
    /\ killed \in [Children -> BOOLEAN]
    /\ clock \in 0..Deadline
    /\ fired \in BOOLEAN
    /\ graced \in BOOLEAN
    /\ main \in {"waiting", "reaping", "joining", "reported"}
    /\ report \in [Checks -> {"none", "result", "timed_out"}]
    /\ seen \in [Checks -> Parts]

\* A result the main thread reports was whole when it read it.
NoTornReport ==
    \A x \in Checks : report[x] = "result" => seen[x] = "full"

\* A probe reported with its result had finished by the deadline: a late
\* result, such as the one a cancelled request writes, is dropped.
ResultsInTime ==
    \A p \in Probes : report[p] = "result" => intime[p]

\* When doctor reports, and so exits, no child it started and no process
\* such a child started in its group is still running.
NoChildAfterExit ==
    main = "reported" =>
        \A c \in Children : child[c] # "running" /\ grand[c] # "running"

\* When doctor reports, every task it started has ended: each probe, and
\* each child's waiter, which has reaped its child.
NoTaskAfterReport ==
    main = "reported" =>
        /\ \A p \in Probes : done[p]
        /\ \A c \in Children : waiter[c] = "done" /\ child[c] = "reaped"

\* The main thread reports, even when probes, children, grandchildren, and
\* processes that left the group hang.
Reports == <>(main = "reported")

=============================================================================
