------------------------- MODULE TraceClipboardRead -------------------------
(***************************************************************************)
(* Checks one recorded run of fx against ClipboardRead's design.           *)
(*                                                                         *)
(* tests/tla/drivers/clipboard_read/driver.ts drives the built fx in tmux  *)
(* with a stub osascript and records what it did as a sequence of steps,   *)
(* written to ClipboardTraces.tla as DriverTrace. Each step is one action  *)
(* of the design with the values the driver saw: the key it sent, the      *)
(* notice a paste showed, how osascript ended, and what reached the        *)
(* screen when the read was collected. Stalled records a key that fx did   *)
(* not read within the driver's wait while osascript ran; the design never *)
(* allows it, because its input loop never waits.                          *)
(*                                                                         *)
(* A step the design cannot take leaves TLC with no next state, so a run   *)
(* that is not a behavior of the design ends in a deadlock. A run that is  *)
(* stutters at its end. The checked-in ClipboardTraces.tla holds sample    *)
(* runs that check.sh requires to be accepted or rejected.                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, ClipboardTraces

CONSTANT Trace

VARIABLES app, loop, job, alive, cancel, result, req, gone, screen, open, gen, borrowed, key,
          pastes, started, settled, wrong, misdropped, clobbered, waited, out, i

CR == INSTANCE ClipboardRead WITH Variant <- "fixed", MaxPastes <- 6, MaxGen <- 2

model == <<app, loop, job, alive, cancel, result, req, gone, screen, open, gen, borrowed, key,
           pastes, started, settled, wrong, misdropped, clobbered, waited, out>>

Step(e) ==
    CASE e.name = "Press" -> CR!Press(e.key)
      [] e.name = "Read" -> CR!ReadText
      [] e.name = "Paste" -> CR!Paste /\ out' = e.seen
      [] e.name = "Quit" -> CR!Quit
      [] e.name = "ChildExits" -> CR!ChildExits(e.result)
      [] e.name = "TimeOut" -> CR!TimeOut
      [] e.name = "CancelKill" -> CR!CancelKill
      [] e.name = "Collect" -> CR!Collect /\ out' = e.seen
      [] e.name = "Exit" -> CR!Exit
      [] e.name = "Stalled" ->
            /\ key # "none"
            /\ ~ENABLED (CR!ReadText \/ CR!Paste \/ CR!Quit)
            /\ UNCHANGED model

Init == CR!Init /\ i = 1

Next ==
    \/ /\ i <= Len(Trace)
       /\ Step(Trace[i])
       /\ i' = i + 1
    \/ /\ i > Len(Trace)
       /\ UNCHANGED <<model, i>>

Spec == Init /\ [][Next]_<<model, i>>

Safe ==
    /\ CR!TypeOK /\ CR!LoopNeverWaits /\ CR!OneChild /\ CR!ChildOnlyWhileReading
    /\ CR!ImageToRequester /\ CR!DropOnlyWhenClosed /\ CR!PickerComposerUntouched
    /\ CR!ShutdownNeverWaitsForDeadline /\ CR!EveryReadSettles /\ CR!NoReadAfterExit
=============================================================================
