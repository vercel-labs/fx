---------------------------- MODULE Doctor ----------------------------
(***************************************************************************)
(* fx doctor's network checks and their one deadline.                      *)
(*                                                                         *)
(* Probes run on threads in the doctor process (the provider catalog       *)
(* request). A probe writes its result into its own slot in two steps, so  *)
(* another thread can see a half-written slot, and then sets the slot's    *)
(* done flag.                                                              *)
(*                                                                         *)
(* Children are processes (one `fx mcp show NAME --json` per MCP server).  *)
(* A child writes its status to its own pipe in two steps and then exits.  *)
(* Doctor reads a child's pipe only after it reaps the child.              *)
(*                                                                         *)
(* Any probe or child can hang at any step: their steps have no fairness.  *)
(* One timer fires at the deadline. The main thread reports once, either   *)
(* when everything is done or when the timer fires, and the process exits *)
(* right after the report.                                                 *)
(*                                                                         *)
(* UseFlag:     a slot counts only with its done flag, and a child's       *)
(*              output only when it exited on its own; otherwise the main  *)
(*              thread takes whatever the slot or pipe holds.              *)
(* UseDeadline: the main thread reports when the timer fires; otherwise    *)
(*              it waits until every probe and child is done (a join).     *)
(* UseKill:     at the deadline the main thread kills every child still    *)
(*              running and reaps every child before it reports.           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Probes, Children, Deadline, UseFlag, UseDeadline, UseKill

VARIABLES slot, done, out, child, killed, clock, fired, main, report, seen

vars == <<slot, done, out, child, killed, clock, fired, main, report, seen>>

Parts == {"empty", "partial", "full"}
Checks == Probes \cup Children

Init ==
    /\ slot = [p \in Probes |-> "empty"]
    /\ done = [p \in Probes |-> FALSE]
    /\ out = [c \in Children |-> "empty"]
    /\ child = [c \in Children |-> "running"]
    /\ killed = [c \in Children |-> FALSE]
    /\ clock = 0
    /\ fired = FALSE
    /\ main = "waiting"
    /\ report = [x \in Checks |-> "none"]
    /\ seen = [x \in Checks |-> "empty"]

Unchanged(vs) == UNCHANGED vs

\* ---- probe threads ----

WritePart(p) ==
    /\ slot[p] = "empty"
    /\ slot' = [slot EXCEPT ![p] = "partial"]
    /\ UNCHANGED <<done, out, child, killed, clock, fired, main, report, seen>>

WriteRest(p) ==
    /\ slot[p] = "partial"
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ UNCHANGED <<done, out, child, killed, clock, fired, main, report, seen>>

Publish(p) ==
    /\ slot[p] = "full"
    /\ ~done[p]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<slot, out, child, killed, clock, fired, main, report, seen>>

\* ---- child processes ----

ChildWritePart(c) ==
    /\ child[c] = "running"
    /\ out[c] = "empty"
    /\ out' = [out EXCEPT ![c] = "partial"]
    /\ UNCHANGED <<slot, done, child, killed, clock, fired, main, report, seen>>

ChildWriteRest(c) ==
    /\ child[c] = "running"
    /\ out[c] = "partial"
    /\ out' = [out EXCEPT ![c] = "full"]
    /\ UNCHANGED <<slot, done, child, killed, clock, fired, main, report, seen>>

ChildExit(c) ==
    /\ child[c] = "running"
    /\ out[c] = "full"
    /\ child' = [child EXCEPT ![c] = "exited"]
    /\ UNCHANGED <<slot, done, out, killed, clock, fired, main, report, seen>>

\* ---- the timer ----

Tick ==
    /\ clock < Deadline
    /\ clock' = clock + 1
    /\ fired' = (clock + 1 = Deadline)
    /\ UNCHANGED <<slot, done, out, child, killed, main, report, seen>>

\* ---- the main thread ----

ProbeFinished(p) == IF UseFlag THEN done[p] ELSE slot[p] # "empty"

ChildFinished(c) ==
    IF UseFlag THEN child[c] = "reaped" /\ ~killed[c] ELSE out[c] # "empty"

AllDone ==
    /\ \A p \in Probes : ProbeFinished(p)
    /\ \A c \in Children : child[c] \in {"exited", "reaped"}

\* Stop waiting: everything is done, or the timer fired.
StopWaiting ==
    /\ main = "waiting"
    /\ IF UseDeadline THEN fired \/ AllDone ELSE AllDone
    /\ child' = IF UseKill
                THEN [c \in Children |-> IF child[c] = "running" THEN "killed" ELSE child[c]]
                ELSE child
    /\ killed' = IF UseKill
                 THEN [c \in Children |-> killed[c] \/ child[c] = "running"]
                 ELSE killed
    /\ main' = "reaping"
    /\ UNCHANGED <<slot, done, out, clock, fired, report, seen>>

\* Reap a child that exited or was killed.
Reap(c) ==
    /\ main = "reaping"
    /\ child[c] \in {"exited", "killed"}
    /\ child' = [child EXCEPT ![c] = "reaped"]
    /\ UNCHANGED <<slot, done, out, killed, clock, fired, main, report, seen>>

\* Read every slot and pipe once, report, and exit.
MainReport ==
    /\ main = "reaping"
    /\ \A c \in Children : child[c] \notin {"exited", "killed"}
    /\ main' = "reported"
    /\ report' = [x \in Checks |->
                    IF x \in Probes
                    THEN IF ProbeFinished(x) THEN "result" ELSE "timed_out"
                    ELSE IF ChildFinished(x) THEN "result" ELSE "timed_out"]
    /\ seen' = [x \in Checks |-> IF x \in Probes THEN slot[x] ELSE out[x]]
    /\ UNCHANGED <<slot, done, out, child, killed, clock, fired>>

ProbeStep == \E p \in Probes : WritePart(p) \/ WriteRest(p) \/ Publish(p)
ChildStep == \E c \in Children : ChildWritePart(c) \/ ChildWriteRest(c) \/ ChildExit(c)
MainStep == StopWaiting \/ (\E c \in Children : Reap(c)) \/ MainReport

Next == ProbeStep \/ ChildStep \/ Tick \/ MainStep

\* Probes and children get no fairness, so any of them can hang forever.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Tick)
    /\ WF_vars(StopWaiting)
    /\ WF_vars(\E c \in Children : Reap(c))
    /\ WF_vars(MainReport)

TypeOK ==
    /\ slot \in [Probes -> Parts]
    /\ done \in [Probes -> BOOLEAN]
    /\ out \in [Children -> Parts]
    /\ child \in [Children -> {"running", "exited", "killed", "reaped"}]
    /\ killed \in [Children -> BOOLEAN]
    /\ clock \in 0..Deadline
    /\ fired \in BOOLEAN
    /\ main \in {"waiting", "reaping", "reported"}
    /\ report \in [Checks -> {"none", "result", "timed_out"}]
    /\ seen \in [Checks -> Parts]

\* A result the main thread reports was whole when it read it.
NoTornReport ==
    \A x \in Checks : report[x] = "result" => seen[x] = "full"

\* When doctor reports, and so exits, no child it started is still running.
NoChildAfterExit ==
    main = "reported" => \A c \in Children : child[c] # "running"

\* The main thread reports, even when probes and children hang.
Reports == <>(main = "reported")

=============================================================================
