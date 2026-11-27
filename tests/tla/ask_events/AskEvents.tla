----------------------------- MODULE AskEvents -----------------------------
(***************************************************************************)
(* Live progress events for `fx ask` (FXC-441): compares today's buffered  *)
(* JSON mode against Design A (stdout JSONL stream + final result line)    *)
(* and Design B (stdout unchanged + --events-file JSONL append file).      *)
(*                                                                         *)
(* Models:                                                                 *)
(*   - Pre-step failures (bad args / missing credentials / image error)    *)
(*   - Model step start/end, recovery wait with concurrent ticker thread   *)
(*   - Parallel tool calls finishing out of order (tool B before tool A)   *)
(*   - Subagent isolation (parent tool events only; child inner steps stay *)
(*     in child live ring)                                                 *)
(*   - SIGTERM and SIGKILL at any point (mid stream, mid tool, mid final)  *)
(*   - Sink closed/full (stdout EPIPE/ENOSPC vs events file ENOSPC)        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Design,   \* "current" | "design-a" | "design-b"
    Mutant,   \* "none" | "buffered" | "unlocked" | "skip-cancel-event"
              \* | "no-final-result" | "file-abort-on-full" | "stdout-clobber"
    Class     \* "all" | "ideal" | "nonideal"

EventNames == {
    "run_started", "step_start", "step_end", "recovery",
    "tool_a_start", "tool_b_start", "tool_a_end", "tool_b_end",
    "notice", "cancel", "run_finished"
}

StdoutKinds == {"event", "final_result", "error_result"}

VARIABLES
    phase,            \* "init" | "pre_fail" | "running" | "model_streaming"
                      \* | "recovery_wait" | "tools_parallel" | "cancelling"
                      \* | "finalizing" | "exited" | "killed"
    stdoutLines,      \* sequence of StdoutKinds written to stdout
    fileLines,        \* sequence of "event" written to events file
    buf,              \* sequence of EventNames buffered in memory (unflushed)
    producedEvents,   \* subset of EventNames produced by the turn
    sinkEvents,       \* subset of EventNames actually flushed to the event sink
    eventCorrupt,     \* TRUE if an unlocked concurrent write or partial write corrupted an event line
    finalCorrupt,     \* TRUE if SIGKILL interrupted mid-final-write
    toolAState,       \* "idle" | "started" | "finished"
    toolBState,       \* "idle" | "started" | "finished"
    writerBusy,       \* "none" | "turn" (models lock-free race window for Mutant = "unlocked")
    tickerReady,      \* TRUE when recovery ticker thread wants to emit recovery status
    sigterm,          \* TRUE once SIGTERM arrives
    sinkClosed,       \* TRUE once stdout (A) or events file (B) fails/closes/fills
    abortedByFile,    \* TRUE if Mutant = "file-abort-on-full" aborted a turn on file ENOSPC
    stepCount,        \* 0..2 bounded model steps
    recoveryCount,    \* 0..1 bounded recovery wait cycles
    exitKind          \* "none" | "ok" | "fail" | "sigterm" | "killed"

vars == <<phase, stdoutLines, fileLines, buf, producedEvents, sinkEvents,
          eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
          tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
          recoveryCount, exitKind>>

UsesEventSink == Design \in {"design-a", "design-b"}

\* Helper: emit one event line `ev` synchronously (or buffer it under "current" / "buffered").
EmitEvent(ev) ==
    /\ producedEvents' = producedEvents \cup {ev}
    /\ IF ~UsesEventSink \/ Mutant = "buffered"
       THEN /\ buf' = Append(buf, ev)
            /\ sinkEvents' = sinkEvents
            /\ stdoutLines' = stdoutLines
            /\ fileLines' = fileLines
       ELSE /\ buf' = buf
            /\ IF sinkClosed
               THEN /\ sinkEvents' = sinkEvents
                    /\ stdoutLines' = stdoutLines
                    /\ fileLines' = fileLines
               ELSE /\ sinkEvents' = sinkEvents \cup {ev}
                    /\ IF Design = "design-a"
                       THEN /\ stdoutLines' = Append(stdoutLines, "event")
                            /\ fileLines' = fileLines
                       ELSE /\ fileLines' = Append(fileLines, "event")
                            /\ stdoutLines' = IF Mutant = "stdout-clobber"
                                              THEN Append(stdoutLines, "event")
                                              ELSE stdoutLines

TypeOK ==
    /\ phase \in {"init", "pre_fail", "running", "model_streaming",
                  "recovery_wait", "tools_parallel", "cancelling",
                  "finalizing", "exited", "killed"}
    /\ \A i \in 1..Len(stdoutLines) : stdoutLines[i] \in StdoutKinds
    /\ \A i \in 1..Len(fileLines) : fileLines[i] = "event"
    /\ \A i \in 1..Len(buf) : buf[i] \in EventNames
    /\ producedEvents \subseteq EventNames
    /\ sinkEvents \subseteq EventNames
    /\ eventCorrupt \in BOOLEAN
    /\ finalCorrupt \in BOOLEAN
    /\ toolAState \in {"idle", "started", "finished"}
    /\ toolBState \in {"idle", "started", "finished"}
    /\ writerBusy \in {"none", "turn"}
    /\ tickerReady \in BOOLEAN
    /\ sigterm \in BOOLEAN
    /\ sinkClosed \in BOOLEAN
    /\ abortedByFile \in BOOLEAN
    /\ stepCount \in 0..2
    /\ recoveryCount \in 0..1
    /\ exitKind \in {"none", "ok", "fail", "sigterm", "killed"}

Init ==
    /\ phase = "init"
    /\ stdoutLines = <<>>
    /\ fileLines = <<>>
    /\ buf = <<>>
    /\ producedEvents = {}
    /\ sinkEvents = {}
    /\ eventCorrupt = FALSE
    /\ finalCorrupt = FALSE
    /\ toolAState = "idle"
    /\ toolBState = "idle"
    /\ writerBusy = "none"
    /\ tickerReady = FALSE
    /\ sigterm = FALSE
    /\ sinkClosed = FALSE
    /\ abortedByFile = FALSE
    /\ stepCount = 0
    /\ recoveryCount = 0
    /\ exitKind = "none"

\* Run starts normally after CLI parsing and preflight.
StartRun ==
    /\ phase = "init"
    /\ phase' = "running"
    /\ EmitEvent("run_started")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount, exitKind>>

\* Run fails before any model step (e.g., missing credentials / image preflight error).
PreStepFail ==
    /\ Class /= "ideal"
    /\ phase = "init"
    /\ phase' = "exited"
    /\ exitKind' = "fail"
    /\ stdoutLines' = IF Mutant = "no-final-result"
                      THEN stdoutLines
                      ELSE Append(stdoutLines, "error_result")
    /\ UNCHANGED <<fileLines, buf, producedEvents, sinkEvents, eventCorrupt,
                   finalCorrupt, toolAState, toolBState, writerBusy, tickerReady,
                   sigterm, sinkClosed, abortedByFile, stepCount, recoveryCount>>

\* Model step begins: enter model_streaming and emit step_start.
BeginModelStep ==
    /\ phase = "running"
    /\ ~sigterm
    /\ stepCount < 2
    /\ writerBusy = "none"
    /\ stepCount' = stepCount + 1
    /\ phase' = "model_streaming"
    /\ EmitEvent("step_start")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, recoveryCount,
                   exitKind>>

\* Transient error triggers recovery wait and arms the background ticker thread.
EnterRecoveryWait ==
    /\ Class /= "ideal"
    /\ phase = "model_streaming"
    /\ ~sigterm
    /\ writerBusy = "none"
    /\ recoveryCount < 1
    /\ recoveryCount' = recoveryCount + 1
    /\ phase' = "recovery_wait"
    /\ tickerReady' = TRUE
    /\ EmitEvent("recovery")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   sigterm, sinkClosed, abortedByFile, stepCount, exitKind>>

\* Recovery wait finishes and resends the model request.
RetryAfterRecovery ==
    /\ phase = "recovery_wait"
    /\ ~sigterm
    /\ writerBusy = "none"
    /\ phase' = "model_streaming"
    /\ tickerReady' = FALSE
    /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   sigterm, sinkClosed, abortedByFile, stepCount, recoveryCount,
                   exitKind>>

\* Model step finishes: start a parallel pair of tools (Step 1) or proceed to finalize (Step 2).
ModelStepProducesTools ==
    /\ phase = "model_streaming"
    /\ ~sigterm
    /\ writerBusy = "none"
    /\ toolAState = "idle"
    /\ toolBState = "idle"
    /\ phase' = "tools_parallel"
    /\ toolAState' = "started"
    /\ toolBState' = "started"
    \* Open a write window when Mutant = "unlocked" to let parallel tool or ticker race.
    /\ writerBusy' = "none"
    /\ EmitEvent("step_end")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, tickerReady, sigterm, sinkClosed,
                   abortedByFile, stepCount, recoveryCount, exitKind>>

BeginToolAWrite ==
    /\ phase = "tools_parallel"
    /\ ~sigterm
    /\ Mutant = "unlocked"
    /\ writerBusy = "none"
    /\ toolAState = "started"
    /\ writerBusy' = "turn"
    /\ UNCHANGED <<phase, stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, finalCorrupt, toolAState, toolBState, tickerReady,
                   sigterm, sinkClosed, abortedByFile, stepCount, recoveryCount,
                   exitKind>>

\* Emit tool_a_start / tool_b_start once tools_parallel begins (simplified atomic pair or individual).
\* Tool A finishes (may run before or after Tool B).
FinishToolA ==
    /\ phase = "tools_parallel"
    /\ ~sigterm
    /\ (writerBusy = "none" \/ (Mutant = "unlocked" /\ writerBusy = "turn"))
    /\ toolAState = "started"
    /\ toolAState' = "finished"
    /\ writerBusy' = "none"
    /\ producedEvents' = producedEvents \cup {"tool_a_start", "tool_a_end"}
    /\ IF ~UsesEventSink \/ Mutant = "buffered"
       THEN /\ buf' = Append(Append(buf, "tool_a_start"), "tool_a_end")
            /\ sinkEvents' = sinkEvents
            /\ stdoutLines' = stdoutLines
            /\ fileLines' = fileLines
       ELSE /\ buf' = buf
            /\ IF sinkClosed
               THEN /\ sinkEvents' = sinkEvents
                    /\ stdoutLines' = stdoutLines
                    /\ fileLines' = fileLines
               ELSE /\ sinkEvents' = sinkEvents \cup {"tool_a_start", "tool_a_end"}
                    /\ IF Design = "design-a"
                       THEN /\ stdoutLines' = Append(Append(stdoutLines, "event"), "event")
                            /\ fileLines' = fileLines
                       ELSE /\ fileLines' = Append(Append(fileLines, "event"), "event")
                            /\ stdoutLines' = IF Mutant = "stdout-clobber"
                                              THEN Append(Append(stdoutLines, "event"), "event")
                                              ELSE stdoutLines
    /\ UNCHANGED <<phase, eventCorrupt, finalCorrupt, toolBState,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount, exitKind>>

\* Tool B finishes (may finish BEFORE Tool A: out-of-order parallel completion).
\* When Mutant = "unlocked" and writerBusy = "turn", Tool B interleaves and corrupts an event line!
FinishToolB ==
    /\ phase = "tools_parallel"
    /\ ~sigterm
    /\ toolBState = "started"
    /\ IF writerBusy = "turn" /\ Mutant = "unlocked"
       THEN /\ eventCorrupt' = TRUE
            /\ toolBState' = "finished"
            /\ UNCHANGED <<phase, stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                           finalCorrupt, toolAState, writerBusy, tickerReady, sigterm,
                           sinkClosed, abortedByFile, stepCount, recoveryCount, exitKind>>
       ELSE /\ writerBusy = "none"
            /\ eventCorrupt' = eventCorrupt
            /\ toolBState' = "finished"
            /\ producedEvents' = producedEvents \cup {"tool_b_start", "tool_b_end"}
            /\ IF ~UsesEventSink \/ Mutant = "buffered"
               THEN /\ buf' = Append(Append(buf, "tool_b_start"), "tool_b_end")
                    /\ sinkEvents' = sinkEvents
                    /\ stdoutLines' = stdoutLines
                    /\ fileLines' = fileLines
               ELSE /\ buf' = buf
                    /\ IF sinkClosed
                       THEN /\ sinkEvents' = sinkEvents
                            /\ stdoutLines' = stdoutLines
                            /\ fileLines' = fileLines
                       ELSE /\ sinkEvents' = sinkEvents \cup {"tool_b_start", "tool_b_end"}
                            /\ IF Design = "design-a"
                               THEN /\ stdoutLines' = Append(Append(stdoutLines, "event"), "event")
                                    /\ fileLines' = fileLines
                               ELSE /\ fileLines' = Append(Append(fileLines, "event"), "event")
                                    /\ stdoutLines' = IF Mutant = "stdout-clobber"
                                                      THEN Append(Append(stdoutLines, "event"), "event")
                                                      ELSE stdoutLines
            /\ UNCHANGED <<phase, finalCorrupt, toolAState, writerBusy,
                           tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                           recoveryCount, exitKind>>

\* Both parallel tools completed -> return to agent loop.
ParallelBatchDone ==
    /\ phase = "tools_parallel"
    /\ ~sigterm
    /\ writerBusy = "none"
    /\ toolAState = "finished"
    /\ toolBState = "finished"
    /\ phase' = "running"
    /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount, exitKind>>

\* Background ticker emits a concurrent recovery/notice event.
\* When Mutant = "unlocked" and writerBusy = "turn", it interleaves and corrupts an event line!
TickerEmit ==
    /\ tickerReady
    /\ phase \in {"model_streaming", "recovery_wait", "tools_parallel"}
    /\ ~sigterm
    /\ tickerReady' = FALSE
    /\ IF writerBusy = "turn" /\ Mutant = "unlocked"
       THEN /\ eventCorrupt' = TRUE
            /\ UNCHANGED <<phase, stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                           finalCorrupt, toolAState, toolBState, writerBusy, sigterm,
                           sinkClosed, abortedByFile, stepCount, recoveryCount, exitKind>>
       ELSE /\ writerBusy = "none"
            /\ eventCorrupt' = eventCorrupt
            /\ EmitEvent("notice")
            /\ UNCHANGED <<phase, finalCorrupt, toolAState, toolBState, writerBusy,
                           sigterm, sinkClosed, abortedByFile, stepCount, recoveryCount,
                           exitKind>>

\* Model step produces final answer and enters finalizing.
ModelStepFinishes ==
    /\ phase = "model_streaming"
    /\ ~sigterm
    /\ writerBusy = "none"
    /\ phase' = "finalizing"
    /\ EmitEvent("step_end")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount, exitKind>>

\* Normal finalization: emit final result line on stdout (unless Design A stdout closed).
FinalizeNormal ==
    /\ phase = "finalizing"
    /\ ~sigterm
    /\ phase' = "exited"
    /\ exitKind' = "ok"
    /\ producedEvents' = producedEvents \cup {"run_finished"}
    /\ IF Design = "design-b"
       THEN /\ buf' = buf
            /\ sinkEvents' = IF ~sinkClosed THEN sinkEvents \cup {"run_finished"} ELSE sinkEvents
            /\ fileLines' = IF ~sinkClosed THEN Append(fileLines, "event") ELSE fileLines
            /\ stdoutLines' = IF Mutant = "no-final-result"
                              THEN stdoutLines
                              ELSE Append(stdoutLines, "final_result")
       ELSE IF Design = "design-a"
       THEN /\ buf' = buf
            /\ fileLines' = fileLines
            /\ IF sinkClosed
               THEN /\ sinkEvents' = sinkEvents
                    /\ stdoutLines' = stdoutLines
               ELSE /\ sinkEvents' = sinkEvents \cup {"run_finished"}
                    /\ stdoutLines' = IF Mutant = "no-final-result"
                                      THEN stdoutLines
                                      ELSE Append(stdoutLines, "final_result")
       ELSE /\ buf' = <<>>
            /\ sinkEvents' = sinkEvents
            /\ fileLines' = fileLines
            /\ stdoutLines' = IF Mutant = "no-final-result"
                              THEN stdoutLines
                              ELSE Append(stdoutLines, "final_result")
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount>>

\* Sink closed / disk full (non-ideal environment).
SinkFails ==
    /\ Class /= "ideal"
    /\ UsesEventSink
    /\ ~sinkClosed
    /\ phase \in {"init", "running", "model_streaming", "recovery_wait", "tools_parallel", "finalizing"}
    /\ sinkClosed' = TRUE
    /\ IF Design = "design-b" /\ Mutant = "file-abort-on-full"
       THEN /\ abortedByFile' = TRUE
            /\ phase' = "exited"
            /\ exitKind' = "fail"
       ELSE /\ abortedByFile' = abortedByFile
            /\ phase' = phase
            /\ exitKind' = exitKind
    /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, stepCount, recoveryCount>>

\* SIGTERM arrives while active.
SigtermArrives ==
    /\ Class /= "ideal"
    /\ ~sigterm
    /\ phase \in {"running", "model_streaming", "recovery_wait", "tools_parallel", "finalizing"}
    /\ sigterm' = TRUE
    /\ phase' = "cancelling"
    /\ writerBusy' = "none"
    /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, finalCorrupt, toolAState, toolBState, tickerReady,
                   sinkClosed, abortedByFile, stepCount, recoveryCount, exitKind>>

\* Process completes clean SIGTERM shutdown (returns 143).
SigtermExits ==
    /\ phase = "cancelling"
    /\ phase' = "exited"
    /\ exitKind' = "sigterm"
    /\ IF ~UsesEventSink \/ Mutant = "skip-cancel-event"
       THEN /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents>>
       ELSE /\ producedEvents' = producedEvents \cup {"cancel"}
            /\ IF Mutant = "buffered"
               THEN /\ buf' = Append(buf, "cancel")
                    /\ sinkEvents' = sinkEvents
                    /\ stdoutLines' = stdoutLines
                    /\ fileLines' = fileLines
               ELSE /\ buf' = <<>>
                    /\ IF sinkClosed
                       THEN /\ sinkEvents' = sinkEvents
                            /\ stdoutLines' = stdoutLines
                            /\ fileLines' = fileLines
                       ELSE /\ sinkEvents' = sinkEvents \cup {"cancel"}
                            /\ IF Design = "design-a"
                               THEN /\ stdoutLines' = Append(stdoutLines, "event")
                                    /\ fileLines' = fileLines
                               ELSE /\ fileLines' = Append(fileLines, "event")
                                    /\ stdoutLines' = IF Mutant = "stdout-clobber"
                                                      THEN Append(stdoutLines, "event")
                                                      ELSE stdoutLines
    /\ UNCHANGED <<eventCorrupt, finalCorrupt, toolAState, toolBState, writerBusy,
                   tickerReady, sigterm, sinkClosed, abortedByFile, stepCount,
                   recoveryCount>>

\* SIGKILL kills the process immediately at any active step, including mid-finalizing.
SigkillHits ==
    /\ Class /= "ideal"
    /\ phase \in {"running", "model_streaming", "recovery_wait", "tools_parallel", "cancelling", "finalizing"}
    /\ finalCorrupt' = (phase = "finalizing" /\ Design = "design-a")
    /\ phase' = "killed"
    /\ exitKind' = "killed"
    /\ UNCHANGED <<stdoutLines, fileLines, buf, producedEvents, sinkEvents,
                   eventCorrupt, toolAState, toolBState, writerBusy, tickerReady,
                   sigterm, sinkClosed, abortedByFile, stepCount, recoveryCount>>

Terminated ==
    /\ phase \in {"exited", "killed"}
    /\ UNCHANGED vars

Next ==
    \/ StartRun
    \/ PreStepFail
    \/ BeginModelStep
    \/ EnterRecoveryWait
    \/ RetryAfterRecovery
    \/ ModelStepProducesTools
    \/ BeginToolAWrite
    \/ FinishToolA
    \/ FinishToolB
    \/ ParallelBatchDone
    \/ TickerEmit
    \/ ModelStepFinishes
    \/ FinalizeNormal
    \/ SinkFails
    \/ SigtermArrives
    \/ SigtermExits
    \/ SigkillHits
    \/ Terminated

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants                                                               *)

\* 1. Every event line a reader ever sees is valid JSON per line (never corrupted by concurrent writes).
ValidJsonPerLine == ~eventCorrupt

\* 2. The final result line on normal exit is the same object `--json` prints today.
FinalResultMatchesJson ==
    (exitKind \in {"ok", "fail"} /\ ~(Design = "design-a" /\ sinkClosed)) =>
        (Len(stdoutLines) >= 1 /\ stdoutLines[Len(stdoutLines)] \in {"final_result", "error_result"})

\* 3. No produced event (nor the cancel marker) is lost before a SIGTERM exit completes.
NoEventLostOnSigterm ==
    (exitKind = "sigterm" /\ ~sinkClosed) =>
        (buf = <<>> /\ producedEvents \subseteq sinkEvents /\ "cancel" \in sinkEvents)

\* 4. A reader that ignores events still gets today's result on normal exit
\*    (and in Design B stdout never contains event lines at all).
IgnoreEventsGetsResult ==
    /\ (Design = "design-b" => \A i \in 1..Len(stdoutLines) : stdoutLines[i] # "event")
    /\ ((exitKind \in {"ok", "fail"} /\ ~(Design = "design-a" /\ sinkClosed)) =>
            (Len(stdoutLines) >= 1 /\ stdoutLines[Len(stdoutLines)] \in {"final_result", "error_result"}))

\* 5. Design B: a full/closed event file never aborts the main turn.
FileFullDoesNotAbortTurn == ~abortedByFile

\* 6. Out-of-order parallel tool completion (B finishes before A) still delivers B's start & end.
OutOfOrderToolsCorrelated ==
    (UsesEventSink /\ Mutant = "none" /\ ~sinkClosed /\ toolBState = "finished" /\ toolAState = "started") =>
        ("tool_b_start" \in sinkEvents /\ "tool_b_end" \in sinkEvents)

=============================================================================
