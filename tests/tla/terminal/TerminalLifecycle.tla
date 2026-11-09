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
(* `Mutation` enables one deliberately broken rule. "daemon_survives" is   *)
(* the behavior with a host daemon: terminals outlive a clean fx exit.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Procs, Ttys, MaxInst, Mutation

ASSUME MaxInst \in Nat \ {0}
ASSUME Mutation \in {"none", "daemon_survives", "exit_skips_close",
                     "profile_wide_recover", "reattach"}

VARIABLES
    run,          \* fx process slot state
    inst,         \* current instance number of each slot (restart = new instance)
    crashedInst,  \* <<slot, instance>> pairs that ended by crash
    owner,        \* owning <<slot, instance>> of each terminal
    alive,        \* terminal's process group is running
    rec,          \* durable terminal record state
    shown,        \* what the owning session's transcript lists
    badInteract,  \* input reached a terminal not owned by the caller instance
    wrongEnd      \* reconciliation ended a terminal whose owner is running

vars == <<run, inst, crashedInst, owner, alive, rec, shown, badInteract, wrongEnd>>

NoOwner == [p |-> CHOOSE x \in Procs : TRUE, i |-> 0]

TypeOK ==
    /\ run \in [Procs -> {"off", "on", "exiting"}]
    /\ inst \in [Procs -> 0..MaxInst]
    /\ crashedInst \subseteq (Procs \X (1..MaxInst))
    /\ owner \in [Ttys -> [p : Procs, i : 0..MaxInst]]
    /\ alive \in [Ttys -> BOOLEAN]
    /\ rec \in [Ttys -> {"none", "live", "ended"}]
    /\ shown \in [Ttys -> {"hidden", "live", "ended"}]
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
    /\ UNCHANGED <<crashedInst, owner, alive, rec, shown, badInteract, wrongEnd>>

\* shell.run tty=true: the in-process registry starts launcher + PTY shell.
Open(x, t) ==
    /\ run[x] = "on"
    /\ rec[t] = "none"
    /\ owner' = [owner EXCEPT ![t] = [p |-> x, i |-> inst[x]]]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ rec' = [rec EXCEPT ![t] = "live"]
    /\ shown' = [shown EXCEPT ![t] = "live"]
    /\ UNCHANGED <<run, inst, crashedInst, badInteract, wrongEnd>>

\* The terminal's command exits on its own; only a running owner records it.
EndNatural(t) ==
    /\ alive[t]
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ rec' = IF OwnerRunning(t) THEN [rec EXCEPT ![t] = "ended"] ELSE rec
    /\ shown' = IF OwnerRunning(t) THEN [shown EXCEPT ![t] = "ended"] ELSE shown
    /\ UNCHANGED <<run, inst, crashedInst, owner, badInteract, wrongEnd>>

\* shell.interact / shell.stop.
Interact(x, t) ==
    /\ run[x] = "on"
    /\ alive[t]
    /\ rec[t] = "live"
    /\ (OwnedBy(t, x) \/ Mutation = "reattach")
    /\ badInteract' = (badInteract \/ ~OwnedBy(t, x))
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, wrongEnd>>

BeginExit(x) ==
    /\ run[x] = "on"
    /\ run' = [run EXCEPT ![x] = "exiting"]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, badInteract, wrongEnd>>

\* Shutdown: hang up the PTY, wait briefly, kill the process tree, record it.
CloseOnExit(x, t) ==
    /\ run[x] = "exiting"
    /\ alive[t]
    /\ OwnedBy(t, x)
    /\ Mutation \notin {"daemon_survives", "exit_skips_close"}
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ rec' = [rec EXCEPT ![t] = "ended"]
    /\ shown' = [shown EXCEPT ![t] = "ended"]
    /\ UNCHANGED <<run, inst, crashedInst, owner, badInteract, wrongEnd>>

FinishExit(x) ==
    /\ run[x] = "exiting"
    /\ \/ Mutation \in {"daemon_survives", "exit_skips_close"}
       \/ \A t \in Ttys : ~(alive[t] /\ OwnedBy(t, x))
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, badInteract, wrongEnd>>

Crash(x) ==
    /\ run[x] \in {"on", "exiting"}
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ crashedInst' = crashedInst \cup {<<x, inst[x]>>}
    /\ UNCHANGED <<inst, owner, alive, rec, shown, badInteract, wrongEnd>>

\* Kernel PTY hangup plus the launcher's stdin-EOF watchdog once the owner
\* is gone. Nobody is left to update the record.
Hangup(t) ==
    /\ alive[t]
    /\ ~OwnerRunning(t)
    /\ Mutation # "daemon_survives"
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, rec, shown, badInteract, wrongEnd>>

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
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, badInteract>>

\* Quiescence: every slot used up and stopped, every terminal gone.
Done ==
    /\ \A x \in Procs : run[x] = "off" /\ inst[x] = MaxInst
    /\ \A t \in Ttys : ~alive[t]
    /\ UNCHANGED vars

Next ==
    \/ \E x \in Procs : Start(x) \/ BeginExit(x) \/ FinishExit(x) \/ Crash(x)
    \/ \E x \in Procs, t \in Ttys :
          Open(x, t) \/ Interact(x, t) \/ CloseOnExit(x, t) \/ Reconcile(x, t)
    \/ \E t \in Ttys : EndNatural(t) \/ Hangup(t)
    \/ Done

Fairness ==
    /\ \A x \in Procs : WF_vars(FinishExit(x))
    /\ \A x \in Procs, t \in Ttys : WF_vars(CloseOnExit(x, t))
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

-----------------------------------------------------------------------------
(* Liveness under weak fairness.                                            *)

ExitCompletes == \A x \in Procs : (run[x] = "exiting") ~> (run[x] = "off")

OrphansEnd == \A t \in Ttys : (alive[t] /\ ~OwnerRunning(t)) ~> ~alive[t]

=============================================================================
