--------------------------- MODULE TerminalCancel ---------------------------
(***************************************************************************)
(* The cancel path of fx's terminal client (src/core/terminal/client.zig)  *)
(* for one request, one caller, one worker thread, and a shutdown.         *)
(*                                                                         *)
(* Actors                                                                  *)
(*   Caller    action_executor.zig: admits the request, sends at most one  *)
(*             cancel while it waits, then takes its completion.           *)
(*   Worker    workerMain: takes the request, allocates the RequestWorker, *)
(*             registers it as active, runs it, publishes the completion.  *)
(*   Shutdown  closeOwnedTerminals: sets stopping and flags the active     *)
(*             workers. It never touches the queue.                        *)
(*                                                                         *)
(* Modes (constant Mode)                                                   *)
(*   current    The code before the one-hold change: take under the lock,  *)
(*              release it, allocate, register under the lock (workerMain *)
(*              and takeIntent). Cancel searches only the queue and the    *)
(*              active table (Runtime.cancel). This is the gap.            *)
(*   design_a   The code now: allocate before the lock, then take and      *)
(*              register in ONE hold (takeAndRegister). A failed allocation *)
(*              or a full table finishes the request as disconnected in    *)
(*              that same hold.                                            *)
(*   mutant_a   design_a with take and register split into two holds.     *)
(*                                                                         *)
(* Class: "ideal" has free slots and no allocation failure. "nonideal"    *)
(* allows a full active table and a failed allocation. Shutdown is allowed *)
(* in both.                                                                *)
(*                                                                         *)
(* Properties                                                              *)
(*   AlwaysFindable        an unfinished request is in a place that cancel *)
(*                         searches: the queue or the active table.        *)
(*   CancelIsFound         a cancel sent while the request is unfinished    *)
(*                         returns true (the literal wording of the task). *)
(*   CancelIsSeen          CancelIsFound, and a request that a cancel found *)
(*                         ends cancelled, unless the cancel came after    *)
(*                         the worker's last check (the accepted race in   *)
(*                         action_executor.zig).                  *)
(*   CancelEnds            (liveness) a cancel that returns true leads to  *)
(*                         a completion.                                   *)
(*                                                                         *)
(* Not modelled here: a request still queued at shutdown. *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  Mode,    \* "current" | "design_a" | "mutant_a"
  Class    \* "ideal" | "nonideal"

ASSUME Mode \in {"current", "design_a", "mutant_a"}
ASSUME Class \in {"ideal", "nonideal"}

VARIABLES
  admitted,          \* BOOLEAN: the request reached the queue
  callerPc,          \* "new" | "waiting" | "done"
  inQueue,           \* BOOLEAN: the request is in the queue
  stopping,          \* BOOLEAN: Shutdown has run
  wpc,               \* worker step, see TypeOK
  allocOk,           \* BOOLEAN: the last RequestWorker allocation worked
  held,              \* BOOLEAN: the worker holds the request outside every table
  active,            \* BOOLEAN: the request is in the active table
  flag,              \* BOOLEAN: the worker's cancelled flag
  pushed,            \* BOOLEAN: a completion is in the sink
  kind,              \* "none" | "response" | "cancelled" | "disconnected"
  cancelSent,        \* BOOLEAN: the caller sent its one cancel
  cancelRet,         \* BOOLEAN: what that cancel returned
  cancelDoneAtSend,  \* BOOLEAN: pushed, at the moment the cancel was sent
  cancelLateAtSend   \* BOOLEAN: the worker had passed its last check when the cancel was sent

vars == <<admitted, callerPc, inQueue, stopping,
          wpc, allocOk, held, active, flag,
          pushed, kind,
          cancelSent, cancelRet, cancelDoneAtSend, cancelLateAtSend>>

callerVars == <<admitted, callerPc>>
cancelVars == <<cancelSent, cancelRet, cancelDoneAtSend, cancelLateAtSend>>

AllocFirst == Mode \in {"design_a", "mutant_a"}
Loop == IF AllocFirst THEN "alloc" ELSE "take"
MayAllocFail == Class = "nonideal"
MayFull == Class = "nonideal"

TypeOK ==
  /\ admitted \in BOOLEAN
  /\ callerPc \in {"new", "waiting", "done"}
  /\ inQueue \in BOOLEAN
  /\ stopping \in BOOLEAN
  /\ wpc \in {"none", "alloc", "take", "unlocked", "register",
              "active", "executing", "checked", "exited"}
  /\ allocOk \in BOOLEAN
  /\ held \in BOOLEAN
  /\ active \in BOOLEAN
  /\ flag \in BOOLEAN
  /\ pushed \in BOOLEAN
  /\ kind \in {"none", "response", "cancelled", "disconnected"}
  /\ cancelSent \in BOOLEAN
  /\ cancelRet \in BOOLEAN
  /\ cancelDoneAtSend \in BOOLEAN
  /\ cancelLateAtSend \in BOOLEAN

Init ==
  /\ admitted = FALSE
  /\ callerPc = "new"
  /\ inQueue = FALSE
  /\ stopping = FALSE
  /\ wpc = "none"
  /\ allocOk = TRUE
  /\ held = FALSE
  /\ active = FALSE
  /\ flag = FALSE
  /\ pushed = FALSE
  /\ kind = "none"
  /\ cancelSent = FALSE
  /\ cancelRet = FALSE
  /\ cancelDoneAtSend = FALSE
  /\ cancelLateAtSend = FALSE

(* ------------------------------ Caller ---------------------------------- *)

\* executor admits the request; a stopping runtime refuses it, and the
\* executor then reports cancelled without a completion from the sink.
Admit ==
  /\ callerPc = "new"
  /\ \/ /\ stopping
        /\ callerPc' = "done"
        /\ UNCHANGED <<admitted, inQueue, wpc>>
     \/ /\ ~stopping
        /\ callerPc' = "waiting"
        /\ admitted' = TRUE
        /\ inQueue' = TRUE
        /\ wpc' = Loop
  /\ UNCHANGED <<stopping, allocOk, held, active, flag,
                 pushed, kind, cancelVars>>

\* One cancel, atomic under Runtime.mutex (Runtime.cancel).
SendCancel ==
  /\ callerPc = "waiting"
  /\ ~cancelSent
  /\ cancelSent' = TRUE
  /\ cancelDoneAtSend' = pushed
  /\ cancelLateAtSend' = (wpc = "checked")
  /\ \/ /\ inQueue                                   \* queue search: push cancelled
        /\ cancelRet' = TRUE
        /\ inQueue' = FALSE
        /\ pushed' = TRUE
        /\ kind' = "cancelled"
        /\ UNCHANGED <<callerVars, stopping, wpc, allocOk, held, active, flag>>
     \/ /\ ~inQueue                                  \* active search: set the flag
        /\ active
        /\ cancelRet' = TRUE
        /\ flag' = TRUE
        /\ UNCHANGED <<callerVars, stopping, inQueue, wpc, allocOk, held,
                       active, pushed, kind>>
     \/ /\ ~inQueue                                  \* nothing found: false
        /\ ~active
        /\ cancelRet' = FALSE
        /\ UNCHANGED <<callerVars, stopping, inQueue, wpc, allocOk, held,
                       active, flag, pushed, kind>>

\* Wait loop: takeCompletionFor, once a completion is in the sink.
TakeCompletion ==
  /\ callerPc = "waiting"
  /\ pushed
  /\ callerPc' = "done"
  /\ UNCHANGED <<admitted, stopping, inQueue, wpc, allocOk, held, active,
                 flag, pushed, kind, cancelVars>>

(* ------------------------------ Shutdown -------------------------------- *)

\* closeOwnedTerminals: stop admissions and the worker's take, and cancel
\* the active workers. The queue is not touched.
Shutdown ==
  /\ ~stopping
  /\ stopping' = TRUE
  /\ flag' = (flag \/ active)
  /\ UNCHANGED <<callerVars, inQueue, wpc, allocOk, held,
                 active, pushed, kind, cancelVars>>

(* ------------------------------ Worker ---------------------------------- *)

\* design_a and mutant_a allocate the RequestWorker first, before any lock.
AllocSpare ==
  /\ wpc = "alloc"
  /\ allocOk' \in (IF MayAllocFail THEN BOOLEAN ELSE {TRUE})
  /\ wpc' = "take"
  /\ UNCHANGED <<callerVars, inQueue, stopping, held, active, flag, pushed,
                 kind, cancelVars>>

\* design_a: takeAndRegister in one hold. A stopping runtime returns with
\* nothing taken. A failed allocation or a full table finishes the request
\* as disconnected in the same hold.
TakeAndRegisterA ==
  /\ Mode = "design_a"
  /\ wpc = "take"
  /\ \/ /\ stopping
        /\ wpc' = "exited"
        /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, held, active,
                       flag, pushed, kind, cancelVars>>
     \/ /\ ~stopping
        /\ inQueue
        /\ inQueue' = FALSE
        /\ \/ /\ allocOk
              /\ active' = TRUE
              /\ wpc' = "active"
              /\ UNCHANGED <<pushed, kind>>
           \/ /\ (MayFull \/ ~allocOk)
              /\ pushed' = TRUE
              /\ kind' = "disconnected"
              /\ wpc' = Loop
              /\ UNCHANGED active
        /\ UNCHANGED <<callerVars, stopping, allocOk, held, flag, cancelVars>>

\* current and mutant_a: the take hold. Current then allocates with the lock
\* free; mutant_a registers in its own second hold.
TakeSplit ==
  /\ Mode \in {"current", "mutant_a"}
  /\ wpc = "take"
  /\ \/ /\ stopping
        /\ wpc' = "exited"
        /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, held, active,
                       flag, pushed, kind, cancelVars>>
     \/ /\ ~stopping
        /\ inQueue
        /\ inQueue' = FALSE
        /\ held' = TRUE
        /\ wpc' = IF AllocFirst THEN "register" ELSE "unlocked"
        /\ UNCHANGED <<callerVars, stopping, allocOk, active, flag, pushed,
                       kind, cancelVars>>

\* current: allocate with the lock free.
AllocLoose ==
  /\ wpc = "unlocked"
  /\ allocOk' \in (IF MayAllocFail THEN BOOLEAN ELSE {TRUE})
  /\ wpc' = "register"
  /\ UNCHANGED <<callerVars, inQueue, stopping, held, active, flag, pushed,
                 kind, cancelVars>>

\* The register hold. A full table or a failed allocation finishes the
\* request as disconnected in the same hold.
RegisterHold ==
  /\ wpc = "register"
  /\ \/ /\ allocOk
        /\ active' = TRUE
        /\ flag' = FALSE
        /\ wpc' = "active"
        /\ held' = FALSE
        /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, pushed, kind,
                       cancelVars>>
     \/ /\ (MayFull \/ ~allocOk)
        /\ pushed' = TRUE
        /\ kind' = "disconnected"
        /\ wpc' = Loop
        /\ held' = FALSE
        /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, active, flag,
                       cancelVars>>

\* complete(): the check before execute.
CheckStart ==
  /\ wpc = "active"
  /\ \/ /\ (stopping \/ flag)
        /\ wpc' = "checked"
        /\ kind' = "cancelled"
     \/ /\ ~(stopping \/ flag)
        /\ wpc' = "executing"
        /\ kind' = kind
  /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, held,
                 active, flag, pushed, cancelVars>>

\* The run ends. The check after execute decides the kind.
ExecDone ==
  /\ wpc = "executing"
  /\ wpc' = "checked"
  /\ kind' = IF flag THEN "cancelled" ELSE "response"
  /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, held,
                 active, flag, pushed, cancelVars>>

\* finishActive: publish the completion and leave the active table.
Publish ==
  /\ wpc = "checked"
  /\ pushed' = TRUE
  /\ active' = FALSE
  /\ wpc' = Loop
  /\ UNCHANGED <<callerVars, inQueue, stopping, allocOk, held,
                 flag, kind, cancelVars>>

(* ------------------------------ Invariants ------------------------------ *)

AlwaysFindable == (admitted /\ ~pushed) => (inQueue \/ active)

CancelIsFound == (cancelSent /\ ~cancelDoneAtSend) => cancelRet

CancelIsSeen ==
  /\ CancelIsFound
  /\ ((cancelSent /\ ~cancelDoneAtSend /\ pushed)
        => ((kind = "cancelled") \/ cancelLateAtSend))

(* ------------------------------ Liveness -------------------------------- *)

CancelEnds == []((cancelSent /\ cancelRet) => <>pushed)

(* ------------------------------ Spec ------------------------------------ *)

Finished == callerPc = "done" /\ UNCHANGED vars

WorkerStep ==
  \/ AllocSpare
  \/ TakeAndRegisterA
  \/ TakeSplit
  \/ AllocLoose
  \/ RegisterHold
  \/ CheckStart
  \/ ExecDone
  \/ Publish

Next ==
  \/ Admit
  \/ SendCancel
  \/ TakeCompletion
  \/ Shutdown
  \/ WorkerStep
  \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(WorkerStep)
=============================================================================
