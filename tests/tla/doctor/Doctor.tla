---------------------------- MODULE Doctor ----------------------------
(***************************************************************************)
(* fx doctor's network checks, their one deadline, and the ending signals. *)
(*                                                                         *)
(* Probes are tasks in the doctor process (the provider catalog request).  *)
(* A probe writes its result into its own slot in two steps, so another    *)
(* thread can see a half-written slot, and then sets the slot's done flag, *)
(* which ends the task. A probe that is cancelled ends too, with a result  *)
(* that says so.                                                           *)
(*                                                                         *)
(* Children are processes (one `fx mcp show NAME --json` per MCP server,   *)
(* and `gh auth status`). The main thread starts them one at a time: it    *)
(* spawns a child, then adds it to the list that a stop reaches. A child   *)
(* writes its status to its own pipe in two steps and then exits. A child  *)
(* may start a process of its own in its group, its grandchild, which      *)
(* holds the child's pipe open while it runs, and a process that leaves    *)
(* the group, which may also hold the pipe. It may also start a server in  *)
(* a group of its own, as the MCP engine does, and then tell the engine's  *)
(* helper about it; the helper ends a server it was told about once the    *)
(* child is gone, and nothing ends a server it was not told about. One     *)
(* waiter task per child reads the pipe to its end, or until it is         *)
(* cancelled, then reaps the child and kills what is left in its group.    *)
(*                                                                         *)
(* Any probe, child, grandchild, server, or process that left the group    *)
(* can hang at any step: their steps have no fairness, except that a       *)
(* cancelled probe ends and a told helper acts. One timer fires at the     *)
(* deadline. An ending signal can arrive at any point, also between a      *)
(* spawn and the step that lists the child. The main thread stops waiting  *)
(* when everything is done, the timer fires, or the signal has arrived. It *)
(* notes which probes finished in time, cancels the others, and kills      *)
(* every child whose waiter is not done. After a reap grace it cancels the *)
(* waiters still blocked and joins every probe and waiter; then it reports *)
(* once and exits, or, after a signal, exits by the signal.                *)
(*                                                                         *)
(* UseFlag:         a slot counts only when its probe finished in time,    *)
(*                  and a child's output only when it exited on its own;   *)
(*                  otherwise the main thread takes what it holds.         *)
(* UseDeadline:     the main thread stops waiting when the timer fires;    *)
(*                  otherwise only when everything is done or a signal     *)
(*                  arrived.                                               *)
(* UseKill:         the main thread kills every child whose waiter is not  *)
(*                  done.                                                  *)
(* UseGroupKill:    each child runs in its own process group, and each     *)
(*                  kill, also the waiter's after the reap, reaches the    *)
(*                  whole group, grandchild included.                      *)
(* UseSweep:        a kill of a running child also kills what it started   *)
(*                  in groups of their own, its server; otherwise only the *)
(*                  helper ends a server.                                  *)
(* UseCancel:       the main thread cancels a probe that did not finish in *)
(*                  time, and after the grace each waiter still blocked.   *)
(* UseJoin:         the main thread reports only after every probe and     *)
(*                  every waiter has ended.                                *)
(* UseStopCheck:    the main thread looks at the signal before it spawns   *)
(*                  each child.                                            *)
(* UseQuietHandler: the signal handler only records the signal; otherwise  *)
(*                  it kills the children listed so far and ends doctor at *)
(*                  once.                                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Probes, Children, Deadline, UseFlag, UseDeadline, UseKill, UseGroupKill, UseSweep,
          UseCancel, UseJoin, UseStopCheck, UseQuietHandler

VARIABLES slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked,
          killed, swept, sig, after_sig, clock, fired, graced, main, report, seen

vars == <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked,
          killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

Parts == {"empty", "partial", "full"}
Checks == Probes \cup Children
Ended == {"reported", "exited"}

Init ==
    /\ slot = [p \in Probes |-> "empty"]
    /\ done = [p \in Probes |-> FALSE]
    /\ cancel = [p \in Probes |-> FALSE]
    /\ intime = [p \in Probes |-> FALSE]
    /\ out = [c \in Children |-> "empty"]
    /\ child = [c \in Children |-> "unstarted"]
    /\ listed = [c \in Children |-> FALSE]
    /\ grand = [c \in Children |-> "none"]
    /\ held = [c \in Children |-> "none"]
    /\ server = [c \in Children |-> "none"]
    /\ waiter = [c \in Children |-> "none"]
    /\ unblocked = [c \in Children |-> FALSE]
    /\ killed = [c \in Children |-> FALSE]
    /\ swept = [c \in Children |-> FALSE]
    /\ sig = FALSE
    /\ after_sig = 0
    /\ clock = 0
    /\ fired = FALSE
    /\ graced = FALSE
    /\ main = "starting"
    /\ report = [x \in Checks |-> "none"]
    /\ seen = [x \in Checks |-> "empty"]

\* ---- probe tasks ----

WritePart(p) ==
    /\ ~done[p]
    /\ slot[p] = "empty"
    /\ slot' = [slot EXCEPT ![p] = "partial"]
    /\ UNCHANGED <<done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

WriteRest(p) ==
    /\ ~done[p]
    /\ slot[p] = "partial"
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ UNCHANGED <<done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

Publish(p) ==
    /\ slot[p] = "full"
    /\ ~done[p]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<slot, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* A cancelled probe writes a result that says so, sets its flag, and ends.
EndCancelled(p) ==
    /\ cancel[p]
    /\ ~done[p]
    /\ slot' = [slot EXCEPT ![p] = "full"]
    /\ done' = [done EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* ---- child processes and what they start ----

ChildWritePart(c) ==
    /\ child[c] = "running"
    /\ out[c] = "empty"
    /\ out' = [out EXCEPT ![c] = "partial"]
    /\ UNCHANGED <<slot, done, cancel, intime, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

ChildWriteRest(c) ==
    /\ child[c] = "running"
    /\ out[c] = "partial"
    /\ out' = [out EXCEPT ![c] = "full"]
    /\ UNCHANGED <<slot, done, cancel, intime, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* The engine tells its helper about a server as soon as it has started it,
\* so a child that ends on its own never leaves one untold.
ChildExit(c) ==
    /\ child[c] = "running"
    /\ out[c] = "full"
    /\ server[c] # "untold"
    /\ child' = [child EXCEPT ![c] = "exited"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* The child starts a process of its own in its group, which inherits the
\* child's pipe.
GrandStart(c) ==
    /\ child[c] = "running"
    /\ grand[c] = "none"
    /\ grand' = [grand EXCEPT ![c] = "running"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

GrandExit(c) ==
    /\ grand[c] = "running"
    /\ grand' = [grand EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* The child starts a process that leaves its group, as setsid does, and keeps
\* the child's pipe. Doctor does not promise to end it, only not to wait on
\* it.
LeaveStart(c) ==
    /\ child[c] = "running"
    /\ held[c] = "none"
    /\ held' = [held EXCEPT ![c] = "holding"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

LeaveExit(c) ==
    /\ held[c] = "holding"
    /\ held' = [held EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* The child starts a server in a group of its own, which does not hold the
\* child's pipe, and tells the helper about it a step later.
ServerStart(c) ==
    /\ child[c] = "running"
    /\ server[c] = "none"
    /\ server' = [server EXCEPT ![c] = "untold"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

ServerTell(c) ==
    /\ child[c] = "running"
    /\ server[c] = "untold"
    /\ server' = [server EXCEPT ![c] = "told"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

ServerExit(c) ==
    /\ server[c] \in {"untold", "told"}
    /\ server' = [server EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* Once the child is gone, the helper ends each server it was told about.
HelperStop(c) ==
    /\ child[c] \in {"exited", "killed", "reaped"}
    /\ server[c] = "told"
    /\ server' = [server EXCEPT ![c] = "gone"]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

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
    /\ UNCHANGED <<slot, done, cancel, intime, out, listed, held, server, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* ---- the timer and the signal ----

Tick ==
    /\ clock < Deadline
    /\ clock' = clock + 1
    /\ fired' = (clock + 1 = Deadline)
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, graced, main, report, seen>>

\* An ending signal while doctor's checks run. The quiet handler records it.
\* The other kind kills each child listed so far, and with group kills its
\* grandchild, and ends doctor at once.
Signal ==
    /\ ~sig
    /\ main \notin Ended
    /\ sig' = TRUE
    /\ IF UseQuietHandler
       THEN UNCHANGED <<child, grand, main>>
       ELSE /\ child' = [c \in Children |-> IF listed[c] /\ child[c] = "running" THEN "killed" ELSE child[c]]
            /\ grand' = IF UseGroupKill
                        THEN [c \in Children |-> IF listed[c] /\ grand[c] = "running" THEN "gone" ELSE grand[c]]
                        ELSE grand
            /\ main' = "exited"
    /\ UNCHANGED <<slot, done, cancel, intime, out, listed, held, server, waiter, unblocked, killed, swept, after_sig, clock, fired, graced, report, seen>>

\* ---- the main thread ----

\* The child the main thread spawned last is listed.
AllListed == \A c \in Children : listed[c] \/ child[c] = "unstarted"

\* Spawn one more child, unless the timer fired, or, with the stop check,
\* the signal has arrived. Its waiter starts with it.
Spawn(c) ==
    /\ main = "starting"
    /\ child[c] = "unstarted"
    /\ AllListed
    /\ ~fired
    /\ UseStopCheck => ~sig
    /\ child' = [child EXCEPT ![c] = "running"]
    /\ waiter' = [waiter EXCEPT ![c] = "reading"]
    /\ after_sig' = IF sig THEN after_sig + 1 ELSE after_sig
    /\ UNCHANGED <<slot, done, cancel, intime, out, listed, grand, held, server, unblocked, killed, swept, sig, clock, fired, graced, main, report, seen>>

\* Add the child just spawned to the list a stop reaches. It may have
\* ended already.
List(c) ==
    /\ main = "starting"
    /\ child[c] # "unstarted"
    /\ ~listed[c]
    /\ listed' = [listed EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, main, report, seen>>

\* Stop starting: every child started, the timer fired, or, with the stop
\* check, the signal has arrived. Children never started stay so.
StartingEnds ==
    /\ main = "starting"
    /\ AllListed
    /\ \/ \A c \in Children : child[c] # "unstarted"
       \/ fired
       \/ UseStopCheck /\ sig
    /\ main' = "waiting"
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced, report, seen>>

AllDone ==
    /\ \A p \in Probes : done[p]
    /\ \A c \in Children : waiter[c] # "reading"

\* Stop waiting: everything is done, the timer fired, or the signal arrived.
\* Note which probes finished in time and cancel the others. Kill each child
\* whose waiter is not done, with group kills its grandchild too, and with
\* the sweep each running child's server.
StopWaiting ==
    /\ main = "waiting"
    /\ IF UseDeadline THEN fired \/ AllDone \/ sig ELSE AllDone \/ sig
    /\ intime' = done
    /\ cancel' = IF UseCancel THEN [p \in Probes |-> ~done[p]] ELSE cancel
    /\ child' = IF UseKill
                THEN [c \in Children |-> IF child[c] = "running" THEN "killed" ELSE child[c]]
                ELSE child
    /\ grand' = IF UseKill /\ UseGroupKill
                THEN [c \in Children |-> IF waiter[c] = "reading" /\ grand[c] = "running" THEN "gone" ELSE grand[c]]
                ELSE grand
    /\ swept' = IF UseKill THEN [c \in Children |-> child[c] = "running"] ELSE swept
    /\ server' = IF UseKill /\ UseSweep
                 THEN [c \in Children |-> IF child[c] = "running" /\ server[c] # "none" THEN "gone" ELSE server[c]]
                 ELSE server
    /\ killed' = IF UseKill
                 THEN [c \in Children |-> killed[c] \/ waiter[c] = "reading"]
                 ELSE killed
    /\ main' = "reaping"
    /\ UNCHANGED <<slot, done, out, listed, held, waiter, unblocked, sig, after_sig, clock, fired, graced, report, seen>>

\* The reap grace ends.
GraceEnds ==
    /\ main = "reaping"
    /\ ~graced
    /\ graced' = TRUE
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, main, report, seen>>

\* After the grace, or once every waiter is done, cancel the waiters still
\* reading.
CancelWaiters ==
    /\ main = "reaping"
    /\ graced \/ \A c \in Children : waiter[c] # "reading"
    /\ unblocked' = IF UseCancel THEN [c \in Children |-> waiter[c] = "reading"] ELSE unblocked
    /\ main' = "joining"
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, killed, swept, sig, after_sig, clock, fired, graced, report, seen>>

ProbeFinished(p) == IF UseFlag THEN intime[p] ELSE slot[p] # "empty"

ChildFinished(c) ==
    IF UseFlag THEN waiter[c] = "done" /\ ~killed[c] ELSE out[c] # "empty"

\* Join every probe and waiter. After a signal, exit by it; otherwise read
\* every slot and pipe once, report, and exit.
MainEnd ==
    /\ main = "joining"
    /\ UseJoin => AllDone
    /\ IF sig
       THEN /\ main' = "exited"
            /\ UNCHANGED <<report, seen>>
       ELSE /\ main' = "reported"
            /\ report' = [x \in Checks |->
                            IF x \in Probes
                            THEN IF ProbeFinished(x) THEN "result" ELSE "timed_out"
                            ELSE IF ChildFinished(x) THEN "result" ELSE "timed_out"]
            /\ seen' = [x \in Checks |-> IF x \in Probes THEN slot[x] ELSE out[x]]
    /\ UNCHANGED <<slot, done, cancel, intime, out, child, listed, grand, held, server, waiter, unblocked, killed, swept, sig, after_sig, clock, fired, graced>>

ProbeStep == \E p \in Probes : WritePart(p) \/ WriteRest(p) \/ Publish(p) \/ EndCancelled(p)
ChildStep == \E c \in Children :
    \/ ChildWritePart(c) \/ ChildWriteRest(c) \/ ChildExit(c)
    \/ GrandStart(c) \/ GrandExit(c) \/ LeaveStart(c) \/ LeaveExit(c)
    \/ ServerStart(c) \/ ServerTell(c) \/ ServerExit(c) \/ HelperStop(c)
    \/ WaiterEnd(c)
MainStep ==
    \/ \E c \in Children : Spawn(c) \/ List(c)
    \/ StartingEnds \/ StopWaiting \/ GraceEnds \/ CancelWaiters \/ MainEnd

Next == ProbeStep \/ ChildStep \/ Tick \/ Signal \/ MainStep

\* Probes, children, grandchildren, servers, and processes that left the
\* group get no fairness, so any of them can hang forever, and the signal may
\* never come. A cancelled probe ends, a waiter that can end does, and the
\* helper acts.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A p \in Probes : WF_vars(EndCancelled(p))
    /\ \A c \in Children : WF_vars(WaiterEnd(c)) /\ WF_vars(HelperStop(c)) /\ WF_vars(List(c))
    /\ WF_vars(\E c \in Children : Spawn(c))
    /\ WF_vars(Tick)
    /\ WF_vars(StartingEnds)
    /\ WF_vars(StopWaiting)
    /\ WF_vars(GraceEnds)
    /\ WF_vars(CancelWaiters)
    /\ WF_vars(MainEnd)

TypeOK ==
    /\ slot \in [Probes -> Parts]
    /\ done \in [Probes -> BOOLEAN]
    /\ cancel \in [Probes -> BOOLEAN]
    /\ intime \in [Probes -> BOOLEAN]
    /\ out \in [Children -> Parts]
    /\ child \in [Children -> {"unstarted", "running", "exited", "killed", "reaped"}]
    /\ listed \in [Children -> BOOLEAN]
    /\ grand \in [Children -> {"none", "running", "gone"}]
    /\ held \in [Children -> {"none", "holding", "gone"}]
    /\ server \in [Children -> {"none", "untold", "told", "gone"}]
    /\ waiter \in [Children -> {"none", "reading", "done"}]
    /\ unblocked \in [Children -> BOOLEAN]
    /\ killed \in [Children -> BOOLEAN]
    /\ swept \in [Children -> BOOLEAN]
    /\ sig \in BOOLEAN
    /\ after_sig \in 0..Cardinality(Children)
    /\ clock \in 0..Deadline
    /\ fired \in BOOLEAN
    /\ graced \in BOOLEAN
    /\ main \in {"starting", "waiting", "reaping", "joining", "reported", "exited"}
    /\ report \in [Checks -> {"none", "result", "timed_out"}]
    /\ seen \in [Checks -> Parts]

\* A result the main thread reports was whole when it read it.
NoTornReport ==
    \A x \in Checks : report[x] = "result" => seen[x] = "full"

\* A probe reported with its result had finished by the deadline: a late
\* result, such as the one a cancelled request writes, is dropped.
ResultsInTime ==
    \A p \in Probes : report[p] = "result" => intime[p]

\* When doctor ends, by its report or by a signal, no child it started and
\* no process such a child started in its group is still running, no server
\* is left that nothing will end, and a child doctor killed while it ran has
\* taken its server with it.
NoChildAfterExit ==
    main \in Ended =>
        \A c \in Children :
            /\ child[c] # "running"
            /\ grand[c] # "running"
            /\ server[c] # "untold"
            /\ swept[c] => server[c] \in {"none", "gone"}

\* When doctor ends, every task it started has ended: each probe, and each
\* child's waiter, which has reaped its child.
NoTaskAfterReport ==
    main \in Ended =>
        /\ \A p \in Probes : done[p]
        /\ \A c \in Children : waiter[c] # "reading" /\ child[c] \in {"unstarted", "reaped"}

\* Once the signal has arrived, doctor starts no child: it looks before each
\* spawn, and in the model a spawn is one step.
NoStartAfterSignalSeen == after_sig = 0

\* Doctor ends, by its report or by the signal, even when probes, children,
\* grandchildren, servers, and processes that left the group hang.
Reports == <>(main \in Ended)

=============================================================================
