---------------------------- MODULE ShellSession ----------------------------
(***************************************************************************)
(* The session the interactive app has open, and what fx tells the user   *)
(* about it (D90): `/status` shows its id and whether it is saved, and     *)
(* quitting prints `fx --resume <id>` for a saved session. Saved means its *)
(* log is on disk, so a resume opens it.                                   *)
(*                                                                         *)
(* One profile outlives many processes. A launch opens a new session,      *)
(* resumes a saved one, or finds no usable store and opens none. In a      *)
(* process, a prompt's turn begins and ends, `/new` and `/clear` open a    *)
(* new session, `/resume` opens a saved one, and `/fork` opens a new       *)
(* session holding the turns before a chosen prompt. A process ends when   *)
(* the user quits or it crashes.                                           *)
(*                                                                         *)
(* `last` is what the latest action showed the user. ShellSessionTrace     *)
(* matches it, the saved ids, and their turns against what the real binary *)
(* did. Report and Handoff are what fx shows; the properties say what is   *)
(* true. Mutant plants one bug so that each property is shown to catch it. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
  Ids,       \* the session ids a run may open
  MaxTurns,  \* the most turns one session may hold
  Mutant     \* "none", or the planted bug in Mutants

None == "none"

Mutants == {
  "none",
  "saved_by_turns",    \* /status counts turns, as `saved` did before D90
  "saved_on_open",     \* /status calls every open session saved
  "exit_by_turns",     \* the exit line counts turns, as it did before D90
  "status_launch_id",  \* /status keeps showing the id the process launched with
  "keep_pristine",     \* leaving a session never prompted saves it
  "reuse_id",          \* a new session may take an id already used
  "fork_held",         \* a fork before the first prompt waits for its first turn
  "drop_on_switch"     \* leaving a saved session deletes it
}

ASSUME None \notin Ids
ASSUME MaxTurns \in Nat \ {0}
ASSUME Mutant \in Mutants

VARIABLES
  running,    \* a process is running
  durable,    \* this process can create sessions
  cur,        \* the open session's id, or None
  turnOpen,   \* a turn is running
  onDisk,     \* the ids whose log is on disk
  turns,      \* the turns each session holds
  used,       \* every id opened so far
  discarded,  \* the ids left before their log reached the disk
  first,      \* the id this process opened when it started
  ended,      \* how the last process ended: "none", "quit" or "crash"
  last        \* what the latest action showed the user

vars == <<running, durable, cur, turnOpen, onDisk, turns, used, discarded, first, ended, last>>

Ops == {"start", "launch", "launch_resume", "launch_no_store", "begin", "end",
        "status", "new", "clear", "resume", "fork", "quit", "crash"}

Obs(op, id, point, saved, handoff) ==
  [op |-> op, id |-> id, point |-> point, saved |-> saved, handoff |-> handoff]

Quiet(op) == Obs(op, None, 0, FALSE, None)

Saved(i) == i # None /\ i \in onDisk

(* ------------------------- what fx shows -------------------------------- *)

(* The `/status` panel's Session line: the id, and whether it says saved.  *)
Report ==
  [ id    |-> IF Mutant = "status_launch_id" THEN first ELSE cur,
    saved |-> CASE Mutant = "saved_by_turns" -> cur # None /\ turns[cur] > 0
                [] Mutant = "saved_on_open"  -> cur # None
                [] OTHER                     -> Saved(cur) ]

(* The id the exit line names, or None when it prints nothing.             *)
Handoff ==
  IF IF Mutant = "exit_by_turns" THEN cur # None /\ turns[cur] > 0 ELSE Saved(cur)
    THEN cur
    ELSE None

(* An id for a session that starts now.                                    *)
FreshIds == IF Mutant = "reuse_id" THEN Ids \ {cur} ELSE Ids \ used

(* Leaving the open session by a switch or a quit: a saved one stays, one  *)
(* never prompted is gone for good (D2, D30). A crash writes nothing.      *)
OnDiskAfterLeave ==
  CASE cur # None /\ Mutant = "keep_pristine"  -> onDisk \cup {cur}
    [] cur # None /\ Mutant = "drop_on_switch" -> onDisk \ {cur}
    [] OTHER                                   -> onDisk

DiscardedAfterLeave ==
  IF cur # None /\ cur \notin onDisk THEN discarded \cup {cur} ELSE discarded

(* -------------------------------- Init ---------------------------------- *)

Init ==
  /\ running = FALSE
  /\ durable = TRUE
  /\ cur = None
  /\ turnOpen = FALSE
  /\ onDisk = {}
  /\ turns = [i \in Ids |-> 0]
  /\ used = {}
  /\ discarded = {}
  /\ first = None
  /\ ended = "none"
  /\ last = Quiet("start")

(* ------------------------------ launches -------------------------------- *)

(* `fx`: a new session, held in memory until its first turn (D2).          *)
Launch(i) ==
  /\ ~running
  /\ i \in FreshIds
  /\ running' = TRUE
  /\ durable' = TRUE
  /\ cur' = i
  /\ used' = used \cup {i}
  /\ first' = i
  /\ last' = Obs("launch", i, 0, FALSE, None)
  /\ UNCHANGED <<turnOpen, onDisk, turns, discarded, ended>>

(* `fx --resume <id>`, as the exit line or `/status` gives it.             *)
LaunchResume(i) ==
  /\ ~running
  /\ i \in onDisk
  /\ running' = TRUE
  /\ durable' = TRUE
  /\ cur' = i
  /\ first' = i
  /\ last' = Obs("launch_resume", i, 0, FALSE, None)
  /\ UNCHANGED <<turnOpen, onDisk, turns, used, discarded, ended>>

(* `fx` where no session can be created: it runs, and saves nothing.       *)
LaunchNoStore ==
  /\ ~running
  /\ running' = TRUE
  /\ durable' = FALSE
  /\ cur' = None
  /\ first' = None
  /\ last' = Quiet("launch_no_store")
  /\ UNCHANGED <<turnOpen, onDisk, turns, used, discarded, ended>>

(* ------------------------------- turns ---------------------------------- *)

(* A prompt starts a turn. The first turn publishes the session (D2).      *)
Begin ==
  /\ running
  /\ ~turnOpen
  /\ cur # None => turns[cur] < MaxTurns
  /\ turnOpen' = TRUE
  /\ IF cur = None
       THEN UNCHANGED <<onDisk, turns>>
       ELSE /\ onDisk' = onDisk \cup {cur}
            /\ turns' = [turns EXCEPT ![cur] = @ + 1]
  /\ last' = Quiet("begin")
  /\ UNCHANGED <<running, durable, cur, used, discarded, first, ended>>

End ==
  /\ running
  /\ turnOpen
  /\ turnOpen' = FALSE
  /\ last' = Quiet("end")
  /\ UNCHANGED <<running, durable, cur, onDisk, turns, used, discarded, first, ended>>

(* `/status`, between turns or while one runs.                             *)
Status ==
  /\ running
  /\ last' = Obs("status", Report.id, 0, Report.saved, None)
  /\ UNCHANGED <<running, durable, cur, turnOpen, onDisk, turns, used, discarded, first, ended>>

(* ----------------------------- switching -------------------------------- *)

(* `/new` or `/clear`. Without a store the shell stays without a session.  *)
NewSession(op, i) ==
  /\ running
  /\ ~turnOpen
  /\ IF durable
       THEN /\ i \in FreshIds
            /\ cur' = i
            /\ used' = used \cup {i}
            /\ onDisk' = OnDiskAfterLeave
            /\ discarded' = DiscardedAfterLeave
       ELSE /\ i = None
            /\ UNCHANGED <<cur, used, onDisk, discarded>>
  /\ last' = Obs(op, i, 0, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, turns, first, ended>>

(* `/resume`: the picker opens another saved session.                      *)
Resume(i) ==
  /\ running
  /\ ~turnOpen
  /\ durable
  /\ cur # None
  /\ i \in onDisk
  /\ i # cur
  /\ cur' = i
  /\ onDisk' = OnDiskAfterLeave
  /\ discarded' = DiscardedAfterLeave
  /\ last' = Obs("resume", i, 0, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, turns, used, first, ended>>

(* `/fork` before prompt p: a new session holding turns 1..p-1, on disk    *)
(* from its open, which the app switches to (D58).                         *)
Fork(p, i) ==
  /\ running
  /\ ~turnOpen
  /\ durable
  /\ cur \in onDisk
  /\ p \in 1..turns[cur]
  /\ i \in FreshIds
  /\ cur' = i
  /\ used' = used \cup {i}
  /\ turns' = [turns EXCEPT ![i] = p - 1]
  /\ onDisk' = IF Mutant = "fork_held" /\ p = 1 THEN OnDiskAfterLeave ELSE OnDiskAfterLeave \cup {i}
  /\ discarded' = DiscardedAfterLeave
  /\ last' = Obs("fork", i, p, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, first, ended>>

(* ------------------------------- ending --------------------------------- *)

(* `/quit`, between turns or while one runs, which ends it, and the exit   *)
(* line.                                                                   *)
Quit ==
  /\ running
  /\ running' = FALSE
  /\ turnOpen' = FALSE
  /\ onDisk' = OnDiskAfterLeave
  /\ discarded' = DiscardedAfterLeave
  /\ ended' = "quit"
  /\ last' = Obs("quit", None, 0, FALSE, Handoff)
  /\ UNCHANGED <<durable, cur, turns, used, first>>

(* The process dies: what was published stays (D2 syncs the publish), a    *)
(* session still in memory is gone, and nothing is printed.                *)
Crash ==
  /\ running
  /\ running' = FALSE
  /\ turnOpen' = FALSE
  /\ discarded' = DiscardedAfterLeave
  /\ ended' = "crash"
  /\ last' = Quiet("crash")
  /\ UNCHANGED <<durable, cur, onDisk, turns, used, first>>

Next ==
  \/ \E i \in Ids : Launch(i) \/ LaunchResume(i)
  \/ LaunchNoStore
  \/ Begin
  \/ End
  \/ Status
  \/ \E i \in Ids \cup {None} : NewSession("new", i) \/ NewSession("clear", i)
  \/ \E i \in Ids : Resume(i)
  \/ \E p \in 1..MaxTurns, i \in Ids : Fork(p, i)
  \/ Quit
  \/ Crash

Spec == Init /\ [][Next]_vars

(* ----------------------------- properties ------------------------------- *)

TypeOK ==
  /\ running \in BOOLEAN
  /\ durable \in BOOLEAN
  /\ cur \in Ids \cup {None}
  /\ turnOpen \in BOOLEAN
  /\ onDisk \subseteq Ids
  /\ turns \in [Ids -> 0..MaxTurns]
  /\ used \subseteq Ids
  /\ discarded \subseteq Ids
  /\ first \in Ids \cup {None}
  /\ ended \in {"none", "quit", "crash"}
  /\ last \in [op: Ops, id: Ids \cup {None}, point: 0..MaxTurns, saved: BOOLEAN, handoff: Ids \cup {None}]

(* `/status` names the session that is open, or none.                      *)
StatusNamesOpenSession == last.op = "status" => last.id = cur

(* A session `/status` calls saved is on disk, so `fx --resume` opens it.  *)
StatusSavedIsOnDisk == last.op = "status" /\ last.saved => last.id \in onDisk

(* A session `/status` calls unsaved is not on disk, so it is not called   *)
(* unsaved while a resume would open it.                                    *)
StatusUnsavedIsAbsent == last.op = "status" /\ ~last.saved => last.id \notin onDisk

(* A session left before it was saved never reaches the disk (D2, D30).    *)
DiscardedNeverSaved == discarded \cap onDisk = {}

(* A launch, `/new` or `/clear` opens a session that is not saved yet.     *)
NewSessionUnsaved ==
  last.op \in {"launch", "new", "clear"} /\ last.id # None => last.id \notin onDisk

(* A resume opens a saved session.                                         *)
ResumeOpensSaved ==
  last.op \in {"launch_resume", "resume"} => last.id = cur /\ cur \in onDisk

(* A fork is on disk from its open and holds the turns before its prompt.  *)
ForkOnDisk == last.op = "fork" => last.id = cur /\ cur \in onDisk /\ turns[cur] = last.point - 1

(* The exit line names only a saved session.                               *)
ExitNamesSaved == last.op = "quit" /\ last.handoff # None => last.handoff \in onDisk

(* The exit line names the session exactly when `/status` calls it saved.  *)
ExitAgreesWithStatus ==
  [][last'.op = "quit" => last'.handoff = IF Saved(cur) THEN cur ELSE None]_vars

(* Every session a launch, `/new`, `/clear` or `/fork` opens is new.       *)
NewIdsAreFresh ==
  [][last'.op \in {"launch", "new", "clear", "fork"} /\ last'.id # None => last'.id \notin used]_vars

(* Nothing in these flows removes a saved session.                         *)
SavedStaysSaved == [][onDisk \subseteq onDisk']_vars

(* ------------------------------ witnesses ------------------------------- *)
(* Each must be violated: the state it rules out is reachable, so the      *)
(* properties above are not vacuous there.                                 *)

(* `/status` on a saved session that holds no turn: a fork before the      *)
(* first prompt.                                                           *)
NoSavedEmptyStatus == ~(last.op = "status" /\ last.saved /\ turns[cur] = 0)

(* `/status` on a session not saved yet.                                   *)
NoUnsavedStatus == ~(last.op = "status" /\ ~last.saved /\ last.id # None)

(* `/status` in a shell without a session.                                 *)
NoStorelessStatus == ~(last.op = "status" /\ last.id = None)

(* An exit line for a session that holds no turn.                          *)
NoEmptyExitLine == ~(last.op = "quit" /\ last.handoff # None /\ turns[last.handoff] = 0)

(* A resume after the process before it crashed.                           *)
NoResumeAfterCrash == ~(last.op = "launch_resume" /\ ended = "crash")
=============================================================================
