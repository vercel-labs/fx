---------------------------- MODULE Doctor ----------------------------
(***************************************************************************)
(* fx doctor's network checks and their one deadline.                      *)
(*                                                                         *)
(* Probes run on threads in the doctor process (the provider catalog       *)
(* request). A probe writes its result into its own slot in two steps, so  *)
(* another thread can see a half-written slot, and then sets the slot's    *)
(* done flag.                                                              *)
(*                                                                         *)
(* Children are processes (one `fx mcp show NAME --json` per MCP server,   *)
(* and `gh auth status`). A child writes its status to its own pipe in two *)
(* steps and then exits. A child may start a process of its own, its       *)
(* grandchild, which holds the child's pipe open while it runs. A child's  *)
(* waiter reaps it only at the end of the pipe, so not while a grandchild  *)
(* runs. Doctor reads a child's pipe only after it reaps the child.        *)
(*                                                                         *)
(* Any probe, child, or grandchild can hang at any step: their steps have  *)
(* no fairness. One timer fires at the deadline. The main thread reports   *)
(* once, either when everything is done or when the timer fires and the   *)
(* reap grace after it ends, and the process exits right after the report. *)
(*                                                                         *)
(* UseFlag:      a slot counts only with its done flag, and a child's      *)
(*               output only when it exited on its own; otherwise the main *)
(*               thread takes whatever the slot or pipe holds.             *)
(* UseDeadline:  the main thread reports when the timer fires; otherwise   *)
(*               it waits until every probe and child is done (a join).    *)
(* UseKill:      at the deadline the main thread kills every child that is *)
(*               not done.                                                 *)
(* UseGroupKill: each child runs in its own process group, and the kill    *)
(*               reaches the whole group, grandchild included; otherwise   *)
(*               only the child.                                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Probes, Children, Deadline, UseFlag, UseDeadline, UseKill, UseGroupKill

VARIABLES slot, done, out, child, grand, killed, clock, fired, graced, main, report, seen

vars == <<slot, done, out, child, grand, killed, clock, fired, graced, main, report, seen>>

Parts == {"empty", "partial", "full"}
Checks == Probes \cup Children

Init ==
    /\ slot = [p \in Probes |-> "empty"]
    /\ done = [p \in Probes |-> FALSE]
    /\ out = [c \in Children |-> "empty"]
    /\ child = [c \in Children |-> "running"]
    /\ grand = [c \in Children |-> "none"]
    /\ killed = [c \in Children |-> FALSE]
    /\ clock = 0
    /\ fired = FALSE
    /\ graced = FALSE
    /\ main = "waiting"
    /\ report = [x \in Checks |-> "none"]
    /\ seen = [x \in Checks |-> "empty"]

\* ---- probe threads ----

WritePart(p) ==
    /\ slot[p] = "empty"
    /\ slot' = [slot EXCEPT ![p] = "partial"]
    /\ UNCHANGED <<done, out, child, grand, killed, clock, fired, graced, main, report, seen>>

WriteRest(p) ==
    /\ slot[p] = "partial"
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ UNCHANGED <<done, out, child, grand, killed, clock, fired, graced, main, report, seen>>

Publish(p) ==
    /\ slot[p] = "full"
    /\ ~done[p]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<slot, out, child, grand, killed, clock, fired, graced, main, report, seen>>

\* ---- child processes and their own children ----

ChildWritePart(c) ==
    /\ child[c] = "running"
    /\ out[c] = "empty"
    /\ out' = [out EXCEPT ![c] = "partial"]
    /\ UNCHANGED <<slot, done, child, grand, killed, clock, fired, graced, main, report, seen>>

ChildWriteRest(c) ==
    /\ child[c] = "running"
    /\ out[c] = "partial"
    /\ out' = [out EXCEPT ![c] = "full"]
    /\ UNCHANGED <<slot, done, child, grand, killed, clock, fired, graced, main, report, seen>>

ChildExit(c) ==
    /\ child[c] = "running"
    /\ out[c] = "full"
    /\ child' = [child EXCEPT ![c] = "exited"]
    /\ UNCHANGED <<slot, done, out, grand, killed, clock, fired, graced, main, report, seen>>

\* The child starts a process of its own, which inherits the child's pipe.
GrandStart(c) ==
    /\ child[c] = "running"
    /\ grand[c] = "none"
    /\ grand' = [grand EXCEPT ![c] = "running"]
    /\ UNCHANGED <<slot, done, out, child, killed, clock, fired, graced, main, report, seen>>

GrandExit(c) ==
    /\ grand[c] = "running"
    /\ grand' = [grand EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, out, child, killed, clock, fired, graced, main, report, seen>>

\* No process holds the child's pipe, so its waiter reads to the end.
PipeClosed(c) == child[c] # "running" /\ grand[c] # "running"

\* ---- the timer ----

Tick ==
    /\ clock < Deadline
    /\ clock' = clock + 1
    /\ fired' = (clock + 1 = Deadline)
    /\ UNCHANGED <<slot, done, out, child, grand, killed, graced, main, report, seen>>

\* ---- the main thread ----

ProbeFinished(p) == IF UseFlag THEN done[p] ELSE slot[p] # "empty"

ChildFinished(c) ==
    IF UseFlag THEN child[c] = "reaped" /\ ~killed[c] ELSE out[c] # "empty"

\* The child's waiter can finish: the child exited and its pipe is closed.
ChildDone(c) == child[c] \in {"exited", "reaped"} /\ PipeClosed(c)

AllDone ==
    /\ \A p \in Probes : ProbeFinished(p)
    /\ \A c \in Children : ChildDone(c)

\* Stop waiting: everything is done, or the timer fired. Kill each child
\* that is not done, and with group kills its grandchild too.
StopWaiting ==
    /\ main = "waiting"
    /\ IF UseDeadline THEN fired \/ AllDone ELSE AllDone
    /\ child' = IF UseKill
                THEN [c \in Children |-> IF child[c] = "running" THEN "killed" ELSE child[c]]
                ELSE child
    /\ grand' = IF UseKill /\ UseGroupKill
                THEN [c \in Children |-> IF ~ChildDone(c) /\ grand[c] = "running" THEN "gone" ELSE grand[c]]
                ELSE grand
    /\ killed' = IF UseKill
                 THEN [c \in Children |-> killed[c] \/ ~ChildDone(c)]
                 ELSE killed
    /\ main' = "reaping"
    /\ UNCHANGED <<slot, done, out, clock, fired, graced, report, seen>>

\* A waiter reaps a child that exited or was killed, once its pipe is closed.
Reap(c) ==
    /\ main = "reaping"
    /\ child[c] \in {"exited", "killed"}
    /\ PipeClosed(c)
    /\ child' = [child EXCEPT ![c] = "reaped"]
    /\ UNCHANGED <<slot, done, out, grand, killed, clock, fired, graced, main, report, seen>>

\* The reap grace ends; the main thread stops waiting for the waiters.
GraceEnds ==
    /\ main = "reaping"
    /\ ~graced
    /\ graced' = TRUE
    /\ UNCHANGED <<slot, done, out, child, grand, killed, clock, fired, main, report, seen>>

\* Read every slot and pipe once, report, and exit.
MainReport ==
    /\ main = "reaping"
    /\ graced \/ \A c \in Children : child[c] \notin {"exited", "killed"}
    /\ main' = "reported"
    /\ report' = [x \in Checks |->
                    IF x \in Probes
                    THEN IF ProbeFinished(x) THEN "result" ELSE "timed_out"
                    ELSE IF ChildFinished(x) THEN "result" ELSE "timed_out"]
    /\ seen' = [x \in Checks |-> IF x \in Probes THEN slot[x] ELSE out[x]]
    /\ UNCHANGED <<slot, done, out, child, grand, killed, clock, fired, graced>>

ProbeStep == \E p \in Probes : WritePart(p) \/ WriteRest(p) \/ Publish(p)
ChildStep == \E c \in Children :
    ChildWritePart(c) \/ ChildWriteRest(c) \/ ChildExit(c) \/ GrandStart(c) \/ GrandExit(c)
MainStep == StopWaiting \/ (\E c \in Children : Reap(c)) \/ GraceEnds \/ MainReport

Next == ProbeStep \/ ChildStep \/ Tick \/ MainStep

\* Probes, children, and grandchildren get no fairness, so any of them can
\* hang forever.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Tick)
    /\ WF_vars(StopWaiting)
    /\ WF_vars(\E c \in Children : Reap(c))
    /\ WF_vars(GraceEnds)
    /\ WF_vars(MainReport)

TypeOK ==
    /\ slot \in [Probes -> Parts]
    /\ done \in [Probes -> BOOLEAN]
    /\ out \in [Children -> Parts]
    /\ child \in [Children -> {"running", "exited", "killed", "reaped"}]
    /\ grand \in [Children -> {"none", "running", "gone"}]
    /\ killed \in [Children -> BOOLEAN]
    /\ clock \in 0..Deadline
    /\ fired \in BOOLEAN
    /\ graced \in BOOLEAN
    /\ main \in {"waiting", "reaping", "reported"}
    /\ report \in [Checks -> {"none", "result", "timed_out"}]
    /\ seen \in [Checks -> Parts]

\* A result the main thread reports was whole when it read it.
NoTornReport ==
    \A x \in Checks : report[x] = "result" => seen[x] = "full"

\* When doctor reports, and so exits, no child it started and no process
\* such a child started is still running.
NoChildAfterExit ==
    main = "reported" =>
        \A c \in Children : child[c] # "running" /\ grand[c] # "running"

\* The main thread reports, even when probes, children, and grandchildren hang.
Reports == <>(main = "reported")

=============================================================================
