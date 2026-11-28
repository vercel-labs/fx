-------------------------- MODULE TerminalLifecycle --------------------------
(***************************************************************************)
(* fx tty terminal lifecycle without the terminal host daemon.            *)
(*                                                                          *)
(* tty=true terminals are owned by the fx process instance that opened     *)
(* them:                                                                    *)
(*   - Normal exit hangs up and reaps every owned terminal before the      *)
(*     process ends, with no prompt.                                       *)
(*   - A crash leaves cleanup to the kernel PTY hangup and the launcher    *)
(*     watchdog (best effort).                                             *)
(*   - A later process (resume, or another fx) reconciles stale durable    *)
(*     records to "ended" only when the owning process instance is gone,   *)
(*     and never reattaches to them.                                       *)
(*                                                                          *)
(* A start has three steps. The first saves the durable record, so a list  *)
(* of the owner's terminals would show it, the second returns the result   *)
(* to the start's caller (the shell tool), and the third is that caller    *)
(* indexing the terminal in its transcript. Until the third, no other call *)
(* of the process may see the terminal (`ProfileStore.starting`, kept by   *)
(* the registry past its return when the caller asks, and ended by the     *)
(* caller), or a second caller of the same process would index it too and  *)
(* the start's caller would index it again.                                *)
(*                                                                          *)
(* `Mutation` enables one deliberately broken rule. "daemon_survives" is   *)
(* the behavior with a host daemon: terminals outlive a clean fx exit.      *)
(* "list_in_flight" is the behavior before `starting` existed: a list shows *)
(* a start that has not finished. "end_at_return" ends `starting` when the *)
(* start returns, before its caller has indexed the terminal.               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Procs, Ttys, MaxInst, Mutation

ASSUME MaxInst \in Nat \ {0}
ASSUME Mutation \in {"none", "daemon_survives", "exit_skips_close",
                     "profile_wide_recover", "reattach", "list_in_flight",
                     "end_at_return"}

VARIABLES
    run,          \* fx process slot state
    inst,         \* current instance number of each slot (restart = new instance)
    crashedInst,  \* <<slot, instance>> pairs that ended by crash
    owner,        \* owning <<slot, instance>> of each terminal
    alive,        \* terminal's process group is running
    rec,          \* durable terminal record state
    shown,        \* what the owning session's transcript lists
    starting,     \* the terminal is hidden from the process's other calls
    pending,      \* the start's caller has not indexed the terminal yet
    returned,     \* the start returned its result to the caller
    early,        \* a second caller indexed the terminal before the start's caller
    badInteract,  \* input reached a terminal not owned by the caller instance
    wrongEnd      \* reconciliation ended a terminal whose owner is running

vars == <<run, inst, crashedInst, owner, alive, rec, shown, starting, pending,
          returned, early, badInteract, wrongEnd>>

NoOwner == [p |-> CHOOSE x \in Procs : TRUE, i |-> 0]

TypeOK ==
    /\ run \in [Procs -> {"off", "on", "exiting"}]
    /\ inst \in [Procs -> 0..MaxInst]
    /\ crashedInst \subseteq (Procs \X (1..MaxInst))
    /\ owner \in [Ttys -> [p : Procs, i : 0..MaxInst]]
    /\ alive \in [Ttys -> BOOLEAN]
    /\ rec \in [Ttys -> {"none", "live", "ended"}]
    /\ shown \in [Ttys -> {"hidden", "live", "ended"}]
    /\ starting \in [Ttys -> BOOLEAN]
    /\ pending \in [Ttys -> BOOLEAN]
    /\ returned \in [Ttys -> BOOLEAN]
    /\ early \in [Ttys -> BOOLEAN]
    /\ badInteract \in BOOLEAN
    /\ wrongEnd \in BOOLEAN

Init ==
    /\ run = [x \in Procs |-> "off"]
    /\ inst = [x \in Procs |-> 0]
    /\ crashedInst = {}
    /\ owner = [t \in Ttys |-> NoOwner]
    /\ alive = [t \in Ttys |-> FALSE]
    /\ rec = [t \in Ttys |-> "none"]
    /\ shown = [t \in Ttys |-> "hidden"]
    /\ starting = [t \in Ttys |-> FALSE]
    /\ pending = [t \in Ttys |-> FALSE]
    /\ returned = [t \in Ttys |-> FALSE]
    /\ early = [t \in Ttys |-> FALSE]
    /\ badInteract = FALSE
    /\ wrongEnd = FALSE

OwnedBy(t, x) == owner[t].p = x /\ owner[t].i = inst[x]

OwnerRunning(t) ==
    /\ run[owner[t].p] \in {"on", "exiting"}
    /\ inst[owner[t].p] = owner[t].i

-----------------------------------------------------------------------------

Start(x) ==
    /\ run[x] = "off"
    /\ inst[x] < MaxInst
    /\ run' = [run EXCEPT ![x] = "on"]
    /\ inst' = [inst EXCEPT ![x] = @ + 1]
    /\ UNCHANGED <<crashedInst, owner, alive, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd>>

\* shell.run tty=true, first step: the in-process registry saves the record,
\* registers the session and starts launcher + PTY shell. The start has not
\* returned, so the transcript does not list the terminal yet.
OpenBegin(x, t) ==
    /\ run[x] = "on"
    /\ rec[t] = "none"
    /\ owner' = [owner EXCEPT ![t] = [p |-> x, i |-> inst[x]]]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ rec' = [rec EXCEPT ![t] = "live"]
    /\ starting' = [starting EXCEPT ![t] = TRUE]
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<run, inst, crashedInst, shown, returned, early, badInteract,
                   wrongEnd>>

\* Second step: the registry's start returns its result to the caller.
ReturnStart(x, t) ==
    /\ pending[t]
    /\ ~returned[t]
    /\ OwnedBy(t, x)
    /\ run[x] \in {"on", "exiting"}
    /\ returned' = [returned EXCEPT ![t] = TRUE]
    /\ starting' = IF Mutation = "end_at_return"
                   THEN [starting EXCEPT ![t] = FALSE] ELSE starting
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, pending,
                   early, badInteract, wrongEnd>>

\* Third step: the caller indexes the terminal, which ends the hiding.
Index(x, t) ==
    /\ pending[t]
    /\ returned[t]
    /\ OwnedBy(t, x)
    /\ run[x] \in {"on", "exiting"}
    /\ shown' = [shown EXCEPT ![t] = IF rec[t] = "live" THEN "live" ELSE "ended"]
    /\ starting' = [starting EXCEPT ![t] = FALSE]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ returned' = [returned EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, early, badInteract,
                   wrongEnd>>

\* What a list of the owner's terminals shows: every record, except that the
\* design hides a start whose caller has not indexed it.
Listed(t) == rec[t] = "live" /\ (~starting[t] \/ Mutation = "list_in_flight")

\* A second call of the same process (`syncOwned`) indexes a listed terminal
\* its transcript does not list yet.
Sync(x, t) ==
    /\ run[x] = "on"
    /\ OwnedBy(t, x)
    /\ Listed(t)
    /\ shown[t] = "hidden"
    /\ shown' = [shown EXCEPT ![t] = "live"]
    /\ early' = [early EXCEPT ![t] = early[t] \/ pending[t]]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, starting, pending,
                   returned, badInteract, wrongEnd>>

\* The terminal's command exits on its own; only a running owner records it.
\* A start whose caller has not indexed it is not listed yet, so nothing is
\* shown.
EndNatural(t) ==
    /\ alive[t]
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ rec' = IF OwnerRunning(t) THEN [rec EXCEPT ![t] = "ended"] ELSE rec
    /\ shown' = IF OwnerRunning(t) /\ shown[t] # "hidden"
                 THEN [shown EXCEPT ![t] = "ended"] ELSE shown
    /\ UNCHANGED <<run, inst, crashedInst, owner, starting, pending, returned, early,
                   badInteract, wrongEnd>>

\* shell.interact / shell.stop. The id comes from the start's result and the
\* runtime knows it only once the caller has indexed it, so no call names a
\* terminal whose caller has not.
Interact(x, t) ==
    /\ run[x] = "on"
    /\ alive[t]
    /\ rec[t] = "live"
    /\ ~pending[t]
    /\ (OwnedBy(t, x) \/ Mutation = "reattach")
    /\ badInteract' = (badInteract \/ ~OwnedBy(t, x))
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, starting,
                   pending, returned, early, wrongEnd>>

BeginExit(x) ==
    /\ run[x] = "on"
    /\ run' = [run EXCEPT ![x] = "exiting"]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd>>

\* Shutdown: hang up the PTY, wait briefly, kill the process tree, record it.
CloseOnExit(x, t) ==
    /\ run[x] = "exiting"
    /\ alive[t]
    /\ OwnedBy(t, x)
    /\ Mutation \notin {"daemon_survives", "exit_skips_close"}
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ rec' = [rec EXCEPT ![t] = "ended"]
    /\ shown' = [shown EXCEPT ![t] = IF shown[t] = "hidden" THEN "hidden" ELSE "ended"]
    /\ UNCHANGED <<run, inst, crashedInst, owner, starting, pending, returned, early,
                   badInteract, wrongEnd>>

\* The process ends, and its in-memory set of starts and its callers go with it.
FinishExit(x) ==
    /\ run[x] = "exiting"
    /\ \/ Mutation \in {"daemon_survives", "exit_skips_close"}
       \/ \A t \in Ttys : ~(alive[t] /\ OwnedBy(t, x))
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ starting' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE starting[t]]
    /\ pending' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE pending[t]]
    /\ returned' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE returned[t]]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, early, badInteract,
                   wrongEnd>>

Crash(x) ==
    /\ run[x] \in {"on", "exiting"}
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ crashedInst' = crashedInst \cup {<<x, inst[x]>>}
    /\ starting' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE starting[t]]
    /\ pending' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE pending[t]]
    /\ returned' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE returned[t]]
    /\ UNCHANGED <<inst, owner, alive, rec, shown, early, badInteract, wrongEnd>>

\* Kernel PTY hangup plus the launcher's stdin-EOF watchdog once the owner
\* is gone. Nobody is left to update the record.
Hangup(t) ==
    /\ alive[t]
    /\ ~OwnerRunning(t)
    /\ Mutation # "daemon_survives"
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd>>

\* Resume (or first terminal use) in process x reconciles stale records.
Reconcile(x, t) ==
    /\ run[x] = "on"
    /\ rec[t] = "live"
    /\ IF Mutation = "profile_wide_recover"
       THEN ~OwnedBy(t, x)
       ELSE ~OwnerRunning(t)
    /\ rec' = [rec EXCEPT ![t] = "ended"]
    /\ shown' = [shown EXCEPT ![t] = "ended"]
    /\ wrongEnd' = (wrongEnd \/ OwnerRunning(t))
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, starting, pending,
                   returned, early, badInteract>>

\* Quiescence: every slot used up and stopped, every terminal gone.
Done ==
    /\ \A x \in Procs : run[x] = "off" /\ inst[x] = MaxInst
    /\ \A t \in Ttys : ~alive[t] /\ ~starting[t] /\ ~pending[t]
    /\ UNCHANGED vars

Next ==
    \/ \E x \in Procs : Start(x) \/ BeginExit(x) \/ FinishExit(x) \/ Crash(x)
    \/ \E x \in Procs, t \in Ttys :
          OpenBegin(x, t) \/ ReturnStart(x, t) \/ Index(x, t) \/ Sync(x, t)
              \/ Interact(x, t) \/ CloseOnExit(x, t) \/ Reconcile(x, t)
    \/ \E t \in Ttys : EndNatural(t) \/ Hangup(t)
    \/ Done

Fairness ==
    /\ \A x \in Procs : WF_vars(FinishExit(x))
    /\ \A x \in Procs, t \in Ttys : WF_vars(CloseOnExit(x, t))
    /\ \A x \in Procs, t \in Ttys : WF_vars(ReturnStart(x, t))
    /\ \A x \in Procs, t \in Ttys : WF_vars(Index(x, t))
    /\ \A t \in Ttys : WF_vars(Hangup(t))

Spec       == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety.                                                                  *)

\* No terminal outlives its fx process except transiently after a crash.
OrphansOnlyAfterCrash ==
    \A t \in Ttys :
        (alive[t] /\ ~OwnerRunning(t)) => <<owner[t].p, owner[t].i>> \in crashedInst

\* A terminal listed as live belongs to a running owner (or a crashed one).
ShownLiveIsOwned ==
    \A t \in Ttys :
        (shown[t] = "live" /\ rec[t] = "live")
            => (OwnerRunning(t) \/ <<owner[t].p, owner[t].i>> \in crashedInst)

\* Resume never reattaches: input only reaches terminals of the caller instance.
NoBadInteract == ~badInteract

\* Reconciliation never ends a terminal owned by another running fx process.
NoWrongEnd == ~wrongEnd

\* No other call of the process indexes a terminal before the start's caller
\* has: the caller indexes it once, from the start's own result. The name
\* keeps the property's first form, "before the start returns".
NoIndexBeforeStartReturns == \A t \in Ttys : ~early[t]

-----------------------------------------------------------------------------
(* Liveness under weak fairness.                                            *)

ExitCompletes == \A x \in Procs : (run[x] = "exiting") ~> (run[x] = "off")

OrphansEnd == \A t \in Ttys : (alive[t] /\ ~OwnerRunning(t)) ~> ~alive[t]

\* A start in flight does not stay hidden: its caller indexes it, or its
\* process ends.
StartReturns == \A t \in Ttys : starting[t] ~> ~starting[t]

\* A start's caller indexes the terminal, or its process ends.
StartIndexed == \A t \in Ttys : pending[t] ~> ~pending[t]

=============================================================================
