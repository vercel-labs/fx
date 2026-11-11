---------------------------- MODULE LiveSessions ----------------------------
(***************************************************************************)
(* `fx sessions --live`: the sessions some fx process has open right now,  *)
(* and what each one and its subagents are doing (`listLive` in            *)
(* src/core/session/session_adapter.zig).                                  *)
(*                                                                         *)
(* A process that has a session open holds an exclusive flock on the      *)
(* session's lock file, and the kernel frees it when the process ends,     *)
(* however it ends (src/core/session_manager/storage.zig tryLock). The     *)
(* scan reads no other signal. For each saved session it tries the lock    *)
(* without waiting: when the try fails, a running fx holds the session and *)
(* it is live; when it succeeds, nobody does, and the scan lets the lock go *)
(* at once (src/core/session_manager/session.zig isBusy). It then reads    *)
(* the live session's log without the lock (D37): whether a turn is open,  *)
(* and each child's newest work by name. A child closed for good is not    *)
(* listed.                                                                 *)
(*                                                                         *)
(* An open that finds the lock held tries again each step until its budget *)
(* runs out (lock_wait_ms, D38), then fails as busy. The scan's own hold   *)
(* lasts far less than one retry step; the model states that as: while the *)
(* scan is about to let a lock go, an opener that already found the scan   *)
(* holding it does not try again. So a scan holds a lock for at most one   *)
(* of an opener's tries (ScanHoldsOneTry), and makes an open fail only     *)
(* when that open's last try lands inside the scan's hold: an open with no *)
(* wait, as a picker's, or one whose budget a real holder used up. The     *)
(* witness-open-fails-on-scan config shows that state is reached.          *)
(*                                                                         *)
(* A process that ends cleanly closes its turn and its children's work in  *)
(* the log. One that crashes leaves them open, and the next open repairs   *)
(* the log first, as crash repair does.                                    *)
(*                                                                         *)
(* The five planted bugs are switches, each FALSE in fx:                   *)
(*   InvertedProbe     a free lock reads as live                           *)
(*   ProbeKeepsLock    the scan never lets a free lock go                  *)
(*   ListClosed        a child closed for good is still listed             *)
(*   ChildTakesParent  a child shows its parent's state, not its own       *)
(*   RecentIsLive      a session counts as live when its log was written   *)
(*                     since its last open, without trying the lock        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Sessions, Procs, Names, Wait,
          InvertedProbe, ProbeKeepsLock, ListClosed, ChildTakesParent, RecentIsLive

ASSUME Wait \in Nat

Free == "free"
Scanner == "scanner"
None == "none"
ChildStates == {"none", "working", "idle", "closed"}
Shown == IF ListClosed THEN {"working", "idle", "closed"} ELSE {"working", "idle"}

VARIABLES
  lock,     \* lock[s]: Free, Scanner, or the process holding it
  proc,     \* proc[p]: what process p is doing
  turn,     \* turn[s]: s's log has a turn open
  child,    \* child[s][n]: child n's newest work, as s's log folds it
  written,  \* written[s]: s's log was written since it was last opened
  scan,     \* the one `fx sessions --live` run
  probes,   \* every probe the current scan made, with who held the lock
  failed    \* the last open that gave up: who held the lock at its last try,
            \* and whether its try before found the scan holding it

vars == <<lock, proc, turn, child, written, scan, probes, failed>>

Off == [st |-> "off", s |-> None, tries |-> 0, saw |-> FALSE]
NoFail == [by |-> None, saw |-> FALSE]

TypeOK ==
  /\ lock \in [Sessions -> Procs \cup {Free, Scanner}]
  /\ \A p \in Procs : proc[p].st \in {"off", "trying", "holding"}
  /\ turn \in [Sessions -> BOOLEAN]
  /\ child \in [Sessions -> [Names -> ChildStates]]
  /\ written \in [Sessions -> BOOLEAN]
  /\ scan.phase \in {"idle", "probing", "done"}

Init ==
  /\ lock = [s \in Sessions |-> Free]
  /\ proc = [p \in Procs |-> Off]
  /\ turn = [s \in Sessions |-> FALSE]
  /\ child = [s \in Sessions |-> [n \in Names |-> "none"]]
  /\ written = [s \in Sessions |-> FALSE]
  /\ scan = [phase |-> "idle", todo |-> {}, peek |-> None, unlock |-> None,
             listed |-> {}, start |-> [s \in Sessions |-> Free], dropped |-> {}]
  /\ probes = {}
  /\ failed = NoFail

\* A lock goes free while a scan runs: the scan may then miss it.
Dropped(s) == IF scan.phase = "probing" THEN scan.dropped \cup {s} ELSE scan.dropped

(* ---------------------------------------------------------------------- *)
(* fx processes                                                            *)

Open(p, s) ==
  /\ proc[p].st = "off"
  /\ proc' = [proc EXCEPT ![p] = [st |-> "trying", s |-> s, tries |-> Wait, saw |-> FALSE]]
  /\ UNCHANGED <<lock, turn, child, written, scan, probes, failed>>

\* Taking a free lock repairs what a crash left open.
Acquire(p) ==
  LET s == proc[p].s IN
  /\ proc[p].st = "trying"
  /\ lock[s] = Free
  /\ lock' = [lock EXCEPT ![s] = p]
  /\ proc' = [proc EXCEPT ![p].st = "holding"]
  /\ turn' = [turn EXCEPT ![s] = FALSE]
  /\ child' = [child EXCEPT ![s] = [n \in Names |-> IF @[n] = "working" THEN "idle" ELSE @[n]]]
  /\ written' = [written EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<scan, probes, failed>>

\* The lock is held: wait a step, or give up when the budget is spent.
Retry(p) ==
  LET s == proc[p].s IN
  /\ proc[p].st = "trying"
  /\ lock[s] # Free
  /\ ~(lock[s] = Scanner /\ proc[p].saw /\ scan.unlock = s)
  /\ IF proc[p].tries > 0
       THEN /\ proc' = [proc EXCEPT ![p].tries = @ - 1, ![p].saw = (lock[s] = Scanner)]
            /\ UNCHANGED failed
       ELSE /\ proc' = [proc EXCEPT ![p] = Off]
            /\ failed' = [by |-> lock[s], saw |-> proc[p].saw]
  /\ UNCHANGED <<lock, turn, child, written, scan, probes>>

Holding(p) == proc[p].st = "holding"

Begin(p) ==
  LET s == proc[p].s IN
  /\ Holding(p) /\ ~turn[s]
  /\ turn' = [turn EXCEPT ![s] = TRUE]
  /\ written' = [written EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<lock, proc, child, scan, probes, failed>>

End(p) ==
  LET s == proc[p].s IN
  /\ Holding(p) /\ turn[s]
  /\ turn' = [turn EXCEPT ![s] = FALSE]
  /\ written' = [written EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<lock, proc, child, scan, probes, failed>>

Spawn(p, n) ==
  LET s == proc[p].s IN
  /\ Holding(p) /\ child[s][n] # "working"
  /\ child' = [child EXCEPT ![s][n] = "working"]
  /\ written' = [written EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<lock, proc, turn, scan, probes, failed>>

Finish(p, n) ==
  LET s == proc[p].s IN
  /\ Holding(p) /\ child[s][n] = "working"
  /\ child' = [child EXCEPT ![s][n] = "idle"]
  /\ written' = [written EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<lock, proc, turn, scan, probes, failed>>

Close(p, n) ==
  LET s == proc[p].s IN
  /\ Holding(p) /\ child[s][n] = "idle"
  /\ child' = [child EXCEPT ![s][n] = "closed"]
  /\ written' = [written EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<lock, proc, turn, scan, probes, failed>>

\* A clean exit closes the open turn and the children's work in the log.
Exit(p) ==
  LET s == proc[p].s IN
  /\ Holding(p)
  /\ lock' = [lock EXCEPT ![s] = Free]
  /\ proc' = [proc EXCEPT ![p] = Off]
  /\ turn' = [turn EXCEPT ![s] = FALSE]
  /\ child' = [child EXCEPT ![s] = [n \in Names |-> IF @[n] = "working" THEN "idle" ELSE @[n]]]
  /\ scan' = [scan EXCEPT !.dropped = Dropped(s)]
  /\ UNCHANGED <<written, probes, failed>>

\* SIGKILL or a crash: the kernel frees the lock, and the log stays as it was.
Crash(p) ==
  LET s == proc[p].s IN
  /\ proc[p].st \in {"trying", "holding"}
  /\ proc' = [proc EXCEPT ![p] = Off]
  /\ IF Holding(p)
       THEN /\ lock' = [lock EXCEPT ![s] = Free]
            /\ scan' = [scan EXCEPT !.dropped = Dropped(s)]
       ELSE UNCHANGED <<lock, scan>>
  /\ UNCHANGED <<turn, child, written, probes, failed>>

(* ---------------------------------------------------------------------- *)
(* The scan                                                                *)

ScanStart ==
  /\ scan.phase \in {"idle", "done"}
  /\ scan' = [phase |-> "probing", todo |-> Sessions, peek |-> None, unlock |-> None,
              listed |-> {}, start |-> lock, dropped |-> {}]
  /\ probes' = {}
  /\ UNCHANGED <<lock, proc, turn, child, written, failed>>

Probe(s) ==
  LET free == lock[s] = Free
      live == IF RecentIsLive THEN written[s] ELSE IF InvertedProbe THEN free ELSE ~free
      tried == ~RecentIsLive
  IN
  /\ scan.phase = "probing" /\ s \in scan.todo
  /\ scan.peek = None /\ scan.unlock = None
  /\ probes' = probes \cup {[s |-> s, live |-> live, by |-> lock[s]]}
  /\ lock' = IF tried /\ free THEN [lock EXCEPT ![s] = Scanner] ELSE lock
  /\ scan' = [scan EXCEPT !.todo = @ \ {s},
                          !.peek = IF live THEN s ELSE None,
                          !.unlock = IF tried /\ free /\ ~ProbeKeepsLock THEN s ELSE None]
  /\ UNCHANGED <<proc, turn, child, written, failed>>

Unlock ==
  /\ scan.unlock # None
  /\ lock' = [lock EXCEPT ![scan.unlock] = Free]
  /\ scan' = [scan EXCEPT !.unlock = None]
  /\ UNCHANGED <<proc, turn, child, written, probes, failed>>

\* What the code prints for a live session, and what the log says.
Agents(s) ==
  {[name |-> n,
    st |-> IF ChildTakesParent THEN (IF turn[s] THEN "working" ELSE "idle") ELSE child[s][n]] :
     n \in {m \in Names : child[s][m] \in Shown}}
Truth(s) == {[name |-> n, st |-> child[s][n]] : n \in {m \in Names : child[s][m] \in {"working", "idle"}}}

Peek ==
  LET s == scan.peek IN
  /\ s # None /\ scan.unlock = None
  /\ scan' = [scan EXCEPT !.peek = None,
                          !.listed = @ \cup {[id |-> s, working |-> turn[s], agents |-> Agents(s), truth |-> Truth(s)]}]
  /\ UNCHANGED <<lock, proc, turn, child, written, probes, failed>>

ScanEnd ==
  /\ scan.phase = "probing" /\ scan.todo = {}
  /\ scan.peek = None /\ scan.unlock = None
  /\ scan' = [scan EXCEPT !.phase = "done"]
  /\ UNCHANGED <<lock, proc, turn, child, written, probes, failed>>

ProcNext ==
  \E p \in Procs :
    \/ \E s \in Sessions : Open(p, s)
    \/ Acquire(p) \/ Retry(p) \/ Begin(p) \/ End(p) \/ Exit(p) \/ Crash(p)
    \/ \E n \in Names : Spawn(p, n) \/ Finish(p, n) \/ Close(p, n)

ScanNext == ScanStart \/ (\E s \in Sessions : Probe(s)) \/ Unlock \/ Peek \/ ScanEnd

Next == ProcNext \/ ScanNext

Spec == Init /\ [][Next]_vars

(* ---------------------------------------------------------------------- *)
(* What must hold                                                          *)

\* Only a running process holds a lock: the kernel frees it on any exit.
LockOwnersRun ==
  \A s \in Sessions : lock[s] \in Procs => Holding(lock[s]) /\ proc[lock[s]].s = s

\* A session reads as live only while a running fx holds it.
ProbeSound == \A r \in probes : r.live => r.by \in Procs

\* A session a running fx holds always reads as live.
ProbeComplete == \A r \in probes : r.by \in Procs => r.live

\* A session held by one process from the scan's start to its end is listed.
HeldIsListed ==
  scan.phase = "done" =>
    \A s \in Sessions :
      (scan.start[s] \in Procs /\ s \notin scan.dropped) => s \in {e.id : e \in scan.listed}

\* Each listed session's subagents are the ones its log has open or idle,
\* each with its own newest work.
AgentsAsLogged == \A e \in scan.listed : e.agents = e.truth

\* A scan holds a lock for at most one of an opener's tries: an open that
\* fails on the scan did not find the scan holding it at its try before.
ScanHoldsOneTry == failed.by = Scanner => ~failed.saw

(* Witnesses: each must be violated, to show the state it names is reached. *)

\* A listed session's process can end before the scan does: the list is a
\* snapshot, true at each session's probe.
NoStaleListing == scan.phase = "done" => \A e \in scan.listed : lock[e.id] \in Procs

\* An open can fail on a scan: its last try lands inside the scan's hold.
NoOpenFailsOnScan == failed.by # Scanner

\* A live session's subagent can be working while the session has no turn open.
NoWorkingChildOfIdle == \A e \in scan.listed : ~e.working => \A a \in e.agents : a.st # "working"
=============================================================================
