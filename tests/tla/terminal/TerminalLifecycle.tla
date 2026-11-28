-------------------------- MODULE TerminalLifecycle --------------------------
(***************************************************************************)
(* fx tty terminal lifecycle without the terminal host daemon.            *)
(*                                                                          *)
(* tty=true terminals are owned by the fx process instance that opened     *)
(* them:                                                                    *)
(*   - Normal exit ends every owned terminal before the process ends, with *)
(*     no prompt, in steps: it records the terminal's process tree, hangs  *)
(*     the terminal up, kills what is left (the recorded tree, and every   *)
(*     process of the terminal's session, even one started after the       *)
(*     record), and waits a bounded time for the PTY to drain. Nothing     *)
(*     that holds the PTY outlives a normal exit.                          *)
(*   - A crash leaves cleanup to the kernel PTY hangup and the launcher    *)
(*     watchdog (best effort): a process that ignores the hangup or left   *)
(*     the shell's job control can survive it.                             *)
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
(* The launcher leads the terminal's session. The host keeps an ended         *)
(* launcher's process entry (`launcher`) after the launcher exits, so its pid *)
(* stays reserved and still names the session, until the session cannot hold *)
(* a process any more, or the exit close has ended what is left in it. The    *)
(* exit close ends the session's processes only while the entry is held: a    *)
(* pid that no entry holds names no session to anyone, and a number that has  *)
(* been reused could name another one. macOS ends a PTY's output when the     *)
(* session leader exits, even while a late child holds the PTY, so the host   *)
(* cannot count on the drain to wait for it.                                  *)
(*                                                                          *)
(* What holds a terminal's PTY keeps its backend from draining. The shell *)
(* does until the hangup. A process the shell starts between the record    *)
(* and the hangup, in its own process group and out of the shell's job     *)
(* table (`lateKid`), does until something kills it: the record does not   *)
(* list it and the hangup misses it. The launcher, which leads the         *)
(* terminal's session, does until it exits. It waits for the release byte  *)
(* that lets its command run, and it stops waiting once its shell has      *)
(* ended: the watchdog that reads the byte stops with the shell, so no     *)
(* byte can arrive. A launcher that did not stop (`stuck`) never closes    *)
(* the PTY. The drain is bounded, so the process may end while something   *)
(* still holds the PTY: the kill step has to leave nothing.                *)
(*                                                                          *)
(* `Mutation` enables one deliberately broken rule. "daemon_survives" is   *)
(* the behavior with a host daemon: terminals outlive a clean fx exit.      *)
(* "list_in_flight" is the behavior before `starting` existed: a list shows *)
(* a start that has not finished. "end_at_return" ends `starting` when the *)
(* start returns, before its caller has indexed the terminal.               *)
(* "record_once" is the exit close that kills only the tree it recorded:   *)
(* a late child survives it. "launcher_wait" is the launcher that waits for *)
(* the release byte even when its shell is gone. "early_reap" is the host   *)
(* that collects the launcher as soon as it has ended, whatever its         *)
(* session still holds: the exit close finds no entry to end the late       *)
(* child by.                                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Procs, Ttys, MaxInst, Mutation

ASSUME MaxInst \in Nat \ {0}
ASSUME Mutation \in {"none", "daemon_survives", "exit_skips_close",
                     "profile_wide_recover", "reattach", "list_in_flight",
                     "end_at_return", "record_once", "launcher_wait", "early_reap"}

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
    wrongEnd,     \* reconciliation ended a terminal whose owner is running
    phase,        \* the exit close: "none", "recorded", "hungup", or "killed"
    lateKid,      \* a process started after the record holds the PTY
    stuck,        \* the launcher waits for a release that cannot come, and holds the PTY
    launcher      \* the host's entry for the terminal's launcher: "none", "held", or "collected"

exitVars == <<phase, lateKid, stuck, launcher>>

vars == <<run, inst, crashedInst, owner, alive, rec, shown, starting, pending,
          returned, early, badInteract, wrongEnd, exitVars>>

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
    /\ phase \in [Ttys -> {"none", "recorded", "hungup", "killed"}]
    /\ lateKid \in [Ttys -> BOOLEAN]
    /\ stuck \in [Ttys -> BOOLEAN]
    /\ launcher \in [Ttys -> {"none", "held", "collected"}]

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
    /\ phase = [t \in Ttys |-> "none"]
    /\ lateKid = [t \in Ttys |-> FALSE]
    /\ stuck = [t \in Ttys |-> FALSE]
    /\ launcher = [t \in Ttys |-> "none"]

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
                   returned, early, badInteract, wrongEnd, exitVars>>

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
    /\ launcher' = [launcher EXCEPT ![t] = "held"]
    /\ UNCHANGED <<run, inst, crashedInst, shown, returned, early, badInteract,
                   wrongEnd, phase, lateKid, stuck>>

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
                   early, badInteract, wrongEnd, exitVars>>

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
                   wrongEnd, exitVars>>

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
                   returned, badInteract, wrongEnd, exitVars>>

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
                   badInteract, wrongEnd, exitVars>>

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
                   pending, returned, early, wrongEnd, exitVars>>

BeginExit(x) ==
    /\ run[x] = "on"
    /\ run' = [run EXCEPT ![x] = "exiting"]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd, exitVars>>

\* Exit close, first step: record the terminal's process tree, which is the
\* shell and what it runs now (`recordProcessTreeForExit`).
ExitRecord(x, t) ==
    /\ run[x] = "exiting"
    /\ alive[t]
    /\ OwnedBy(t, x)
    /\ phase[t] = "none"
    /\ Mutation \notin {"daemon_survives", "exit_skips_close"}
    /\ phase' = [phase EXCEPT ![t] = "recorded"]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, starting,
                   pending, returned, early, badInteract, wrongEnd, lateKid,
                   stuck, launcher>>

\* Between the record and the hangup, the shell may start a process in its own
\* process group and out of its job table (`sleep 30 & disown`), which the
\* hangup misses. Only a live shell starts one, so no process joins the
\* session once the shell has ended.
ForkLate(x, t) ==
    /\ run[x] = "exiting"
    /\ OwnedBy(t, x)
    /\ phase[t] = "recorded"
    /\ alive[t]
    /\ ~lateKid[t]
    /\ lateKid' = [lateKid EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, starting,
                   pending, returned, early, badInteract, wrongEnd, phase,
                   stuck, launcher>>

\* Second step: hang up the shell's process group and the recorded tree. The
\* shell ends, and the launcher with it. The shell may also have ended before
\* the host released its command, which leaves the launcher in its wait for
\* the release.
ExitHangup(x, t) ==
    /\ run[x] = "exiting"
    /\ OwnedBy(t, x)
    /\ phase[t] = "recorded"
    /\ phase' = [phase EXCEPT ![t] = "hungup"]
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ \/ /\ Mutation = "launcher_wait"
          /\ stuck' = [stuck EXCEPT ![t] = TRUE]
       \/ stuck' = stuck
    /\ UNCHANGED <<run, inst, crashedInst, owner, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd, lateKid, launcher>>

\* Third step, after the grace: kill what the hangup left, record the terminal
\* as lost, and end every process of the launcher's session, which a late
\* child is in. A program that moved to its own session is not in it. The
\* session's processes are ended only while the host still holds the
\* launcher's entry, which is what proves whose session the pid names.
ExitKill(x, t) ==
    /\ run[x] = "exiting"
    /\ OwnedBy(t, x)
    /\ phase[t] = "hungup"
    /\ phase' = [phase EXCEPT ![t] = "killed"]
    /\ rec' = [rec EXCEPT ![t] = "ended"]
    /\ shown' = [shown EXCEPT ![t] = IF shown[t] = "hidden" THEN "hidden" ELSE "ended"]
    /\ lateKid' = IF Mutation = "record_once" \/ launcher[t] # "held"
                  THEN lateKid ELSE [lateKid EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, starting, pending,
                   returned, early, badInteract, wrongEnd, stuck, launcher>>

\* The host collects an ended launcher, once, and so gives up its entry. The
\* design does it when the session can hold no process any more (nothing
\* joins an empty session), or after the exit close has ended what was left
\* in it. A terminal's close and the freeing of its session are the same
\* step here. The planted `early_reap` does it as soon as the launcher ended.
ReapLauncher(x, t) ==
    /\ OwnerRunning(t)
    /\ OwnedBy(t, x)
    /\ launcher[t] = "held"
    /\ ~alive[t] /\ ~stuck[t]
    /\ \/ ~lateKid[t]
       \/ phase[t] = "killed"
       \/ Mutation = "early_reap"
    /\ launcher' = [launcher EXCEPT ![t] = "collected"]
    /\ UNCHANGED <<run, inst, crashedInst, owner, alive, rec, shown, starting,
                   pending, returned, early, badInteract, wrongEnd, phase,
                   lateKid, stuck>>

\* The process ends, and its in-memory set of starts and its callers go with it.
FinishExit(x) ==
    /\ run[x] = "exiting"
    \* The drain is bounded: what still holds the PTY (`lateKid`, `stuck`) does
    \* not hold the exit back.
    /\ \/ Mutation \in {"daemon_survives", "exit_skips_close"}
       \/ \A t \in Ttys :
             OwnedBy(t, x) => (~alive[t] /\ phase[t] \in {"none", "killed"})
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ starting' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE starting[t]]
    /\ pending' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE pending[t]]
    /\ returned' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE returned[t]]
    \* The process's entries go with it: the system collects what it left.
    /\ launcher' = [t \in Ttys |->
                     IF OwnedBy(t, x) /\ launcher[t] = "held"
                     THEN "collected" ELSE launcher[t]]
    /\ UNCHANGED <<inst, crashedInst, owner, alive, rec, shown, early, badInteract,
                   wrongEnd, phase, lateKid, stuck>>

Crash(x) ==
    /\ run[x] \in {"on", "exiting"}
    /\ run' = [run EXCEPT ![x] = "off"]
    /\ crashedInst' = crashedInst \cup {<<x, inst[x]>>}
    /\ starting' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE starting[t]]
    /\ pending' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE pending[t]]
    /\ returned' = [t \in Ttys |-> IF OwnedBy(t, x) THEN FALSE ELSE returned[t]]
    /\ phase' = [t \in Ttys |-> IF OwnedBy(t, x) THEN "none" ELSE phase[t]]
    /\ launcher' = [t \in Ttys |->
                     IF OwnedBy(t, x) /\ launcher[t] = "held"
                     THEN "collected" ELSE launcher[t]]
    /\ UNCHANGED <<inst, owner, alive, rec, shown, early, badInteract, wrongEnd,
                   lateKid, stuck>>

\* Kernel PTY hangup plus the launcher's stdin-EOF watchdog once the owner
\* is gone. Nobody is left to update the record. A process that ignores the
\* hangup, as a late child in its own group does, survives it.
Hangup(t) ==
    /\ alive[t] \/ stuck[t]
    /\ ~OwnerRunning(t)
    /\ Mutation # "daemon_survives"
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ stuck' = [stuck EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<run, inst, crashedInst, owner, rec, shown, starting, pending,
                   returned, early, badInteract, wrongEnd, phase, lateKid,
                   launcher>>

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
                   returned, early, badInteract, exitVars>>

\* Quiescence: every slot used up and stopped, every terminal gone.
Done ==
    /\ \A x \in Procs : run[x] = "off" /\ inst[x] = MaxInst
    /\ \A t \in Ttys : ~alive[t] /\ ~starting[t] /\ ~pending[t]
    /\ UNCHANGED vars

Next ==
    \/ \E x \in Procs : Start(x) \/ BeginExit(x) \/ FinishExit(x) \/ Crash(x)
    \/ \E x \in Procs, t \in Ttys :
          OpenBegin(x, t) \/ ReturnStart(x, t) \/ Index(x, t) \/ Sync(x, t)
              \/ Interact(x, t) \/ Reconcile(x, t)
              \/ ExitRecord(x, t) \/ ForkLate(x, t) \/ ExitHangup(x, t)
              \/ ExitKill(x, t)
              \/ ReapLauncher(x, t)
    \/ \E t \in Ttys : EndNatural(t) \/ Hangup(t)
    \/ Done

Fairness ==
    /\ \A x \in Procs : WF_vars(FinishExit(x))
    /\ \A x \in Procs, t \in Ttys : WF_vars(ExitRecord(x, t))
    /\ \A x \in Procs, t \in Ttys : WF_vars(ExitHangup(x, t))
    /\ \A x \in Procs, t \in Ttys : WF_vars(ExitKill(x, t))
    /\ \A x \in Procs, t \in Ttys : WF_vars(ReapLauncher(x, t))
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

\* After a normal exit nothing of the terminal holds the PTY, which would keep
\* its backend from draining: no process started after the exit close recorded
\* the tree, and not a launcher that went on waiting. A crash can leave a
\* process that ignores the hangup.
NoHolderAfterCleanExit ==
    \A t \in Ttys :
        (~OwnerRunning(t) /\ (lateKid[t] \/ stuck[t]))
            => <<owner[t].p, owner[t].i>> \in crashedInst

\* While its owner runs, a terminal's session that still holds a process keeps
\* the launcher's entry held: the entry is what lets the exit close tell whose
\* processes they are.
LauncherHeldWhileSessionHasMembers ==
    \A t \in Ttys :
        (OwnerRunning(t) /\ (lateKid[t] \/ stuck[t])) => launcher[t] = "held"

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

\* An ended launcher is collected, so the entries do not pile up: by the host,
\* or with its process.
LauncherCollected ==
    \A t \in Ttys :
        (launcher[t] = "held" /\ ~alive[t] /\ ~stuck[t]) ~> launcher[t] # "held"

\* A start in flight does not stay hidden: its caller indexes it, or its
\* process ends.
StartReturns == \A t \in Ttys : starting[t] ~> ~starting[t]

\* A start's caller indexes the terminal, or its process ends.
StartIndexed == \A t \in Ttys : pending[t] ~> ~pending[t]

=============================================================================
