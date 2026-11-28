----------------------------- MODULE SessionOpen -----------------------------
(***************************************************************************)
(* Opening a saved session from the session picker (`fx -r`, `/resume`):  *)
(* `SessionPickerOpen` in src/core/app/session_persistence.zig and the     *)
(* `startSessionPickerOpen` / `pollSessionPickerOpen` steps in             *)
(* src/core/app/app_session_runtime.zig.                                   *)
(*                                                                         *)
(* Two actors. The UI thread takes keys, slices the replay, and installs.  *)
(* A worker opens the session (converting v1 first), decodes its durable  *)
(* state, reads the newest cycle's turns, and later finalizes the          *)
(* detached projection the UI replayed into. The UI never waits on the     *)
(* worker: Esc marks the task abandoned, and the result a finished,        *)
(* abandoned task leaves is freed by whichever thread holds it.            *)
(*                                                                         *)
(* Mode "current" is fx before: Enter runs every step on the UI thread.    *)
(* Mode "design-a" runs the replay on the worker as well, where it reads   *)
(* app state (tool registry, labels) the UI thread changes. Mode          *)
(* "design-b" is the design: replay in slices on the UI thread, every      *)
(* slow step that touches no app state on the worker.                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Rows,           \* sessions listed in the picker
    MaxRequests,    \* bound on Enter presses that start an open
    Mode,           \* "current", "design-a", "design-b"
    Failures,       \* opens may fail: busy in another fx, unreadable, out of memory
    \* Planted bugs; each must break the rule its config names.
    BugInstallAfterCancel,  \* a finished open installs though Esc cancelled it
    BugSecondEnter,         \* Enter while an open runs starts another one
    BugEscFreesWorkerResult,\* Esc frees the result the worker still holds
    BugDropKeepsLock,       \* a dropped result is freed without closing it
    BugPendingStartsEarly   \* a queued open takes the worker from an abandoned one

None == "none"

VARIABLES
    ui,          \* "free" or "busy": busy while the UI thread does slow work
    phase,       \* the open the picker shows: "idle", "reading", "replaying", "finalizing"
    req,         \* the request the picker shows as opening, 0 for none
    reqRow,      \* [1..MaxRequests -> Rows \cup {None}]: the row each request opens
    nextReq,
    task,        \* the worker: [stage, req, done, abandoned]
    pending,     \* a request queued behind an abandoned task, 0 for none
    owner,       \* [1..MaxRequests -> {"none", "worker", "ui", "freed", "failed", "installed"}]
    locks,       \* [Rows -> Nat]: writer locks this process holds on each session
    cancelled,   \* requests Esc, a picker close, or quit cancelled
    installed,   \* the request installed, 0 while the old session stays open
    oldOpen,     \* the session open before the picker (or the startup state)
    pickerOpen,
    quitting,
    exited

vars == <<ui, phase, req, reqRow, nextReq, task, pending, owner, locks, cancelled,
          installed, oldOpen, pickerOpen, quitting, exited>>

Reqs == 1..MaxRequests
NoTask == [stage |-> "none", req |-> 0, done |-> FALSE, abandoned |-> FALSE]

TypeOK ==
    /\ ui \in {"free", "busy"}
    /\ phase \in {"idle", "reading", "replaying", "finalizing"}
    /\ req \in 0..MaxRequests
    /\ nextReq \in 1..(MaxRequests + 1)
    /\ task.stage \in {"none", "read", "replay", "finalize"}
    /\ pending \in 0..MaxRequests
    /\ owner \in [Reqs -> {"none", "worker", "ui", "freed", "failed", "installed"}]
    /\ locks \in [Rows -> 0..3]

Init ==
    /\ ui = "free"
    /\ phase = "idle"
    /\ req = 0
    /\ reqRow = [r \in Reqs |-> None]
    /\ nextReq = 1
    /\ task = NoTask
    /\ pending = 0
    /\ owner = [r \in Reqs |-> "none"]
    /\ locks = [r \in Rows |-> 0]
    /\ cancelled = {}
    /\ installed = 0
    /\ oldOpen = TRUE
    /\ pickerOpen = TRUE
    /\ quitting = FALSE
    /\ exited = FALSE

KeysTaken == ui = "free" /\ ~exited /\ ~quitting

StartTask(r) == task' = [stage |-> "read", req |-> r, done |-> FALSE, abandoned |-> FALSE]

(* Enter on a row. A second Enter while an open runs does nothing. *)
Enter(row) ==
    /\ KeysTaken
    /\ pickerOpen
    /\ installed = 0
    /\ nextReq <= MaxRequests
    /\ (phase = "idle" \/ BugSecondEnter)
    /\ LET r == nextReq IN
       /\ nextReq' = nextReq + 1
       /\ reqRow' = [reqRow EXCEPT ![r] = row]
       /\ req' = r
       /\ IF Mode = "current"
            \* fx before: the UI thread itself opens, decodes, replays,
            \* finalizes, and installs before it reads the next key.
            THEN /\ ui' = "busy"
                 /\ phase' = "reading"
                 /\ UNCHANGED <<task, pending>>
            ELSE /\ ui' = "free"
                 /\ phase' = "reading"
                 /\ IF task.stage = "none"
                      THEN /\ StartTask(r) /\ pending' = pending
                      ELSE IF BugPendingStartsEarly
                        THEN /\ StartTask(r) /\ pending' = pending
                        ELSE /\ pending' = r /\ UNCHANGED task
    /\ UNCHANGED <<owner, locks, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

(* Today's synchronous open, step by step on the UI thread. *)
CurrentOpen ==
    /\ Mode = "current"
    /\ ui = "busy"
    /\ phase = "reading"
    /\ \/ /\ locks[reqRow[req]] = 0
          /\ locks' = [locks EXCEPT ![reqRow[req]] = 1]
          /\ owner' = [owner EXCEPT ![req] = "ui"]
          /\ phase' = "replaying"
          /\ ui' = "busy"
       \/ /\ Failures
          /\ owner' = [owner EXCEPT ![req] = "failed"]   \* busy elsewhere, or unreadable
          /\ phase' = "idle"
          /\ ui' = "free"
          /\ UNCHANGED locks
    /\ UNCHANGED <<req, reqRow, nextReq, task, pending, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

CurrentInstall ==
    /\ Mode = "current"
    /\ ui = "busy"
    /\ phase = "replaying"
    /\ installed' = req
    /\ owner' = [owner EXCEPT ![req] = "installed"]
    /\ oldOpen' = FALSE
    /\ pickerOpen' = FALSE
    /\ phase' = "idle"
    /\ ui' = "free"
    /\ UNCHANGED <<req, reqRow, nextReq, task, pending, locks, cancelled, quitting, exited>>

(* The worker's read: open (and convert), durable state, newest cycle.   *)
(* It checks the cancel flag before it opens; once open, it finishes.     *)
WorkerRead ==
    /\ task.stage = "read"
    /\ ~task.done
    /\ LET row == reqRow[task.req] IN
       IF task.abandoned
         THEN /\ task' = [task EXCEPT !.done = TRUE]
              /\ UNCHANGED <<locks, owner>>
         ELSE \/ /\ locks[row] = 0
                 /\ locks' = [locks EXCEPT ![row] = @ + 1]
                 /\ owner' = [owner EXCEPT ![task.req] = "worker"]
                 /\ task' = [task EXCEPT !.done = TRUE]
              \/ /\ Failures
                 /\ task' = [task EXCEPT !.done = TRUE]   \* busy elsewhere or unreadable
                 /\ owner' = [owner EXCEPT ![task.req] = "failed"]
                 /\ UNCHANGED locks
    /\ UNCHANGED <<ui, phase, req, reqRow, nextReq, pending, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

(* design-a's replay on the worker. *)
WorkerReplay ==
    /\ Mode = "design-a"
    /\ task.stage = "replay"
    /\ ~task.done
    /\ task' = [task EXCEPT !.done = TRUE]
    /\ UNCHANGED <<ui, phase, req, reqRow, nextReq, pending, owner, locks, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

WorkerFinalize ==
    /\ task.stage = "finalize"
    /\ ~task.done
    /\ task' = [task EXCEPT !.done = TRUE]
    /\ UNCHANGED <<ui, phase, req, reqRow, nextReq, pending, owner, locks, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

Free(r) ==
    /\ owner' = [owner EXCEPT ![r] = "freed"]
    /\ locks' = IF owner[r] \in {"worker", "ui"} /\ ~BugDropKeepsLock
                  THEN [locks EXCEPT ![reqRow[r]] = @ - 1]
                  ELSE locks

(* After a task ends: start the request queued behind it, if any. *)
NextTask ==
    IF pending # 0 /\ ~quitting
      THEN /\ StartTask(pending) /\ pending' = 0
      ELSE /\ task' = NoTask /\ pending' = pending

(* The UI takes a finished task. *)
PollTask ==
    /\ Mode # "current"
    /\ task.stage # "none"
    /\ task.done
    /\ ~exited
    /\ LET r == task.req IN
       IF (task.abandoned \/ r \in cancelled) /\ ~(BugInstallAfterCancel /\ owner[r] = "worker")
         THEN /\ (IF owner[r] = "worker" THEN Free(r) ELSE UNCHANGED <<owner, locks>>)
              /\ NextTask
              /\ UNCHANGED <<phase, req, installed, oldOpen, pickerOpen>>
         ELSE IF owner[r] # "worker"
           \* The open failed: the row says why, and the picker stays.
           THEN /\ NextTask
                /\ phase' = "idle" /\ req' = 0
                /\ UNCHANGED <<owner, locks, installed, oldOpen, pickerOpen>>
           ELSE CASE task.stage = "read" ->
                       IF Mode = "design-a"
                         THEN /\ task' = [task EXCEPT !.stage = "replay", !.done = FALSE]
                              /\ phase' = "replaying"
                              /\ req' = r
                              /\ UNCHANGED <<owner, locks, pending, installed, oldOpen, pickerOpen>>
                         ELSE /\ owner' = [owner EXCEPT ![r] = "ui"]
                              /\ task' = NoTask
                              /\ phase' = "replaying"
                              /\ req' = r
                              /\ UNCHANGED <<locks, pending, installed, oldOpen, pickerOpen>>
                  [] task.stage = "replay" ->
                       /\ task' = [task EXCEPT !.stage = "finalize", !.done = FALSE]
                       /\ phase' = "finalizing"
                       /\ req' = r
                       /\ UNCHANGED <<owner, locks, pending, installed, oldOpen, pickerOpen>>
                  [] task.stage = "finalize" ->
                       \* The one atomic install: the old session closes here.
                       /\ owner' = [owner EXCEPT ![r] = "installed"]
                       /\ installed' = r
                       /\ oldOpen' = FALSE
                       /\ pickerOpen' = FALSE
                       /\ task' = NoTask
                       /\ phase' = "idle"
                       /\ req' = 0
                       /\ UNCHANGED <<locks, pending>>
    /\ UNCHANGED <<ui, reqRow, nextReq, cancelled, quitting, exited>>

(* design-b: the UI replays a slice, and after the last one hands the    *)
(* projection to the worker to finalize.                                  *)
ReplaySlice ==
    /\ Mode = "design-b"
    /\ phase = "replaying"
    /\ req # 0
    /\ ~quitting
    /\ task.stage = "none"
    /\ owner[req] = "ui"
    /\ \/ UNCHANGED <<phase, task, owner>>      \* another slice to go
       \/ /\ phase' = "finalizing"
          /\ task' = [stage |-> "finalize", req |-> req, done |-> FALSE, abandoned |-> FALSE]
          /\ owner' = [owner EXCEPT ![req] = "worker"]
    /\ UNCHANGED <<ui, req, reqRow, nextReq, pending, locks, cancelled, installed, oldOpen, pickerOpen, quitting, exited>>

(* Esc while a row opens: cancel it, keep the picker. *)
CancelOpen ==
    /\ KeysTaken
    /\ phase # "idle"
    /\ cancelled' = cancelled \cup {req}
    /\ phase' = "idle"
    /\ req' = 0
    /\ IF pending = req
         THEN /\ pending' = 0 /\ UNCHANGED <<task, owner, locks>>
         ELSE IF task.stage # "none" /\ task.req = req
           THEN /\ task' = [task EXCEPT !.abandoned = TRUE]
                /\ pending' = pending
                /\ IF BugEscFreesWorkerResult /\ owner[req] = "worker"
                     THEN Free(req)
                     ELSE UNCHANGED <<owner, locks>>
           ELSE \* The UI holds the replay: free it now.
                /\ Free(req) /\ UNCHANGED <<task, pending>>
    /\ UNCHANGED <<ui, reqRow, nextReq, installed, oldOpen, pickerOpen, quitting, exited>>

(* Esc with nothing opening closes the picker. *)
ClosePicker ==
    /\ KeysTaken
    /\ pickerOpen
    /\ phase = "idle"
    /\ pickerOpen' = FALSE
    /\ UNCHANGED <<ui, phase, req, reqRow, nextReq, task, pending, owner, locks, cancelled, installed, oldOpen, quitting, exited>>

(* Ctrl+C twice, or a signal: stop the open, then exit once the worker is *)
(* done, freeing what it left.                                            *)
Quit ==
    /\ ui = "free"
    /\ ~quitting
    /\ ~exited
    /\ quitting' = TRUE
    /\ cancelled' = IF req # 0 THEN cancelled \cup {req} ELSE cancelled
    /\ pending' = 0
    /\ task' = IF task.stage # "none" THEN [task EXCEPT !.abandoned = TRUE] ELSE task
    /\ IF phase = "replaying" /\ req # 0 /\ owner[req] = "ui"
         THEN Free(req) ELSE UNCHANGED <<owner, locks>>
    /\ phase' = "idle"
    /\ req' = 0
    /\ UNCHANGED <<ui, reqRow, nextReq, installed, oldOpen, pickerOpen, exited>>

Exit ==
    /\ quitting
    /\ ~exited
    /\ (task.stage = "none" \/ task.done)
    /\ LET r == task.req IN
       IF task.stage # "none" /\ owner[r] = "worker" THEN Free(r) ELSE UNCHANGED <<owner, locks>>
    /\ task' = NoTask
    /\ exited' = TRUE
    /\ UNCHANGED <<ui, phase, req, reqRow, nextReq, pending, cancelled, installed, oldOpen, pickerOpen, quitting>>

Next ==
    \/ \E row \in Rows : Enter(row)
    \/ CurrentOpen \/ CurrentInstall
    \/ WorkerRead \/ WorkerReplay \/ WorkerFinalize
    \/ PollTask \/ ReplaySlice
    \/ CancelOpen \/ ClosePicker
    \/ Quit \/ Exit

Spec == Init /\ [][Next]_vars

ReplayLast ==
    /\ ReplaySlice
    /\ phase' = "finalizing"

(* Workers and the UI's polling run; keys may stop at any time. *)
FairSpec ==
    /\ Spec
    /\ WF_vars(CurrentOpen) /\ WF_vars(CurrentInstall)
    /\ WF_vars(WorkerRead) /\ WF_vars(WorkerReplay) /\ WF_vars(WorkerFinalize)
    /\ WF_vars(PollTask) /\ WF_vars(ReplayLast) /\ WF_vars(Exit)

-----------------------------------------------------------------------------
(* Rules. *)

(* R2.1: the UI thread never does the slow steps, so keys and paints go on. *)
UiNeverSlow == ui = "free"

(* design-a's flaw: the replay reads app state the UI thread changes. *)
NoWorkerReadsAppState == task.stage # "replay"

(* An open Esc, a picker close, or quit cancelled never installs. *)
NoHalfOpen == installed # 0 => installed \notin cancelled

(* A second Enter opens nothing extra: at most one open the person waits on. *)
Live == {r \in Reqs : reqRow[r] # None /\ r \notin cancelled /\ owner[r] \in {"none", "worker", "ui"}}
OneOpen == Cardinality(Live) <= 1

(* Nothing is freed while the worker can still touch it (no use after   *)
(* free), and a result the worker holds belongs to its task.            *)
NoUseAfterFree ==
    \A r \in Reqs :
        /\ owner[r] = "freed" => ~(task.stage # "none" /\ task.req = r)
        /\ owner[r] = "worker" => (task.stage # "none" /\ task.req = r)

(* One writer per session (R3.6): this process never holds a lock twice. *)
OneLockPerSession == \A row \in Rows : locks[row] <= 1

(* R3.9: once nothing is in flight, the only lock left is the installed  *)
(* session's.                                                             *)
Quiet == task.stage = "none" /\ pending = 0 /\ phase = "idle"
LocksOwned ==
    Quiet => \A row \in Rows :
        locks[row] = IF installed # 0 /\ reqRow[installed] = row THEN 1 ELSE 0

(* The open session stays open until the one atomic install. *)
OldKeptUntilInstall == (installed = 0) = oldOpen

(* No thread or lock outlives exit. *)
ExitClean == exited => (task.stage = "none" /\ LocksOwned)

Rules ==
    /\ TypeOK
    /\ NoHalfOpen
    /\ OneOpen
    /\ NoUseAfterFree
    /\ OneLockPerSession
    /\ LocksOwned
    /\ OldKeptUntilInstall
    /\ ExitClean
(* An open nobody cancels ends: installed, or failed with its reason   *)
(* shown. And a cancelled one gives its lock back.                      *)
OpensSettle ==
    \A r \in Reqs :
        (reqRow[r] # None) ~> (installed = r \/ owner[r] \in {"failed", "freed"} \/ (r \in cancelled /\ owner[r] = "none"))
LocksComeBack == <>[](Quiet \/ exited) => <>[]LocksOwned
=============================================================================
