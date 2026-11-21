------------------------------ MODULE TraceIds ------------------------------
(***************************************************************************)
(* The turn, step, and subagent ids fx hands out (nextTurnId, nextStepId,  *)
(* and nextSubagentId in src/core/shared/debug_trace.zig), and what they   *)
(* decide on the screen: which tool block each call joins, and whether a   *)
(* call shows at all.                                                      *)
(*                                                                         *)
(* A call joins the block keyed by {turn id, anchor step id}, and calls    *)
(* with equal keys share one block (src/ui/transcript/                     *)
(* tool_group_projection.zig). A step starts in the turn's active group,   *)
(* or a new one anchored at itself (presentationGroupForStep in            *)
(* src/core/agent/runtime/tool_presentation.zig). Text ahead of a streamed *)
(* tool start anchors the group at the step (onStreamToolStart in          *)
(* assistant_stream.zig), and so does any text in a step whose calls       *)
(* arrive without a streamed start; text after a streamed tool start ends  *)
(* the active group (transitionPresentationGroup). A streamed tool start   *)
(* after text that does not end a line first writes a line break, which    *)
(* counts as text after the start. Calls that arrive without a streamed    *)
(* start reach the transcript when they run, after all of the step's text. *)
(*                                                                         *)
(* The transcript admits a call only when its turn id is above every turn  *)
(* that has finished (admitStart in src/core/output/activity_runtime.zig); *)
(* a call it refuses shows nowhere.                                        *)
(*                                                                         *)
(* Bug picks the id generator:                                             *)
(*   "none"               counters from 1, the design on every target      *)
(*   "wasi_constant"      fx-term.wasm before the fix: every id is 1       *)
(*   "step_constant"      only step ids stay 1                             *)
(*   "turn_constant"      only turn ids stay 1                             *)
(*   "subagent_constant"  only subagent ids stay 1                         *)
(*   "zero_start"         counters from 0, where 0 means "no id"           *)
(* The model does not say how the screen shows a call whose turn or group  *)
(* id is 0, which the transcript ignores; IdsNonZero rules such ids out.   *)
(*                                                                         *)
(* TraceIdsTrace.tla replays sessions of the real fx-term.wasm through     *)
(* these actions; tests/tla/drivers/debug_trace/driver.ts runs it.         *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Turns,  \* turns in one session
    Steps,  \* tool steps per turn before the final answer
    Calls,  \* tool calls in one step
    Bug

Bugs == {"none", "wasi_constant", "step_constant", "turn_constant", "subagent_constant", "zero_start"}

ASSUME Turns \in Nat /\ Steps \in Nat /\ Calls \in Nat \ {0} /\ Bug \in Bugs

VARIABLES
    nextTurn, nextStep, nextSubagent,  \* the three counters
    turn,       \* the session's current turn, counted from 1
    phase,      \* "idle" between turns, "turn" while one runs
    tid,        \* the current turn's id
    fence,      \* the highest turn id a finished turn had
    step,       \* tool steps the current turn has run
    active,     \* <<>> or <<group>>: the group the next step starts in
    rows,       \* what reached the transcript, in order
    turnIds, stepIds, subagentIds  \* every id handed out, in order

vars == <<nextTurn, nextStep, nextSubagent, turn, phase, tid, fence, step, active, rows,
          turnIds, stepIds, subagentIds>>

Start == IF Bug = "zero_start" THEN 0 ELSE 1

\* The id a counter hands out, and whether this generator ignores its counter.
Id(counter, constant) == IF constant THEN 1 ELSE counter
TurnConstant == Bug \in {"wasi_constant", "turn_constant"}
StepConstant == Bug \in {"wasi_constant", "step_constant"}
SubagentConstant == Bug \in {"wasi_constant", "subagent_constant"}

Group(t, s) == [turn |-> t, anchor |-> s]
NoKey == Group(0, 0)
Max(a, b) == IF a > b THEN a ELSE b

TextRow(k, j, where) ==
    [kind |-> "text", turn |-> k, step |-> j, where |-> where, call |-> 0, key |-> NoKey, shown |-> TRUE]
ToolRow(k, j, c, key, shown) ==
    [kind |-> "tool", turn |-> k, step |-> j, where |-> "", call |-> c, key |-> key, shown |-> shown]

Init ==
    /\ nextTurn = Start /\ nextStep = Start /\ nextSubagent = Start
    /\ turn = 0 /\ phase = "idle" /\ tid = 0 /\ fence = 0 /\ step = 0 /\ active = <<>>
    /\ rows = <<>>
    /\ turnIds = <<>> /\ stepIds = <<>> /\ subagentIds = <<>>

\* A new session: a fresh fx-term.wasm instance starts every counter again.
Reset ==
    /\ nextTurn' = Start /\ nextStep' = Start /\ nextSubagent' = Start
    /\ turn' = 0 /\ phase' = "idle" /\ tid' = 0 /\ fence' = 0 /\ step' = 0 /\ active' = <<>>
    /\ rows' = <<>>
    /\ turnIds' = <<>> /\ stepIds' = <<>> /\ subagentIds' = <<>>

\* A prompt starts a turn: it takes a turn id, and no group is active yet.
StartTurn ==
    /\ phase = "idle" /\ turn < Turns
    /\ LET id == Id(nextTurn, TurnConstant) IN
        /\ tid' = id
        /\ turnIds' = Append(turnIds, id)
    /\ nextTurn' = nextTurn + 1
    /\ turn' = turn + 1
    /\ phase' = "turn"
    /\ step' = 0
    /\ active' = <<>>
    /\ UNCHANGED <<nextStep, nextSubagent, fence, rows, stepIds, subagentIds>>

\* One model step that calls n tools. before: text ahead of the first call;
\* after: text behind it; streamed: the provider streamed the tool input, so
\* fx saw the tool start while the reply streamed.
ToolStep(n, before, after, streamed) ==
    /\ phase = "turn" /\ step < Steps
    /\ LET sid == Id(nextStep, StepConstant)
           own == Group(tid, sid)
           start == IF active /= <<>> /\ Head(active).turn = tid THEN Head(active) ELSE own
           provisional == IF streamed /\ before /\ tid /= 0 /\ sid /= 0 THEN own ELSE start
           key == IF ~streamed /\ (before \/ after) THEN own ELSE provisional
           textAfterStart == streamed /\ (before \/ after)
           admitted == tid /= 0 /\ tid > fence
           k == turn
           j == step + 1
           beforeRows == IF before THEN <<TextRow(k, j, "before")>> ELSE <<>>
           afterRows == IF after THEN <<TextRow(k, j, "after")>> ELSE <<>>
           toolRows == [c \in 1..n |-> ToolRow(k, j, c, key, admitted)]
       IN
        /\ stepIds' = Append(stepIds, sid)
        /\ rows' = rows \o beforeRows \o
                   (IF streamed THEN toolRows \o afterRows ELSE afterRows \o toolRows)
        /\ active' = IF textAfterStart THEN <<>> ELSE <<key>>
    /\ nextStep' = nextStep + 1
    /\ step' = step + 1
    /\ UNCHANGED <<nextTurn, nextSubagent, turn, phase, tid, fence, turnIds, subagentIds>>

\* The final answer: a step with text and no tool call ends the turn, and the
\* transcript fences the turn's id.
FinalStep ==
    /\ phase = "turn"
    /\ stepIds' = Append(stepIds, Id(nextStep, StepConstant))
    /\ nextStep' = nextStep + 1
    /\ rows' = Append(rows, TextRow(turn, step + 1, "final"))
    /\ fence' = Max(fence, tid)
    /\ active' = <<>>
    /\ phase' = "idle"
    /\ UNCHANGED <<nextTurn, nextSubagent, turn, tid, step, turnIds, subagentIds>>

\* A subagent starts. fx-term.wasm runs none (src/core/hosts/runtime_profile.zig),
\* so only the id rules see it.
StartSubagent ==
    /\ phase = "turn" /\ Len(subagentIds) < Turns
    /\ subagentIds' = Append(subagentIds, Id(nextSubagent, SubagentConstant))
    /\ nextSubagent' = nextSubagent + 1
    /\ UNCHANGED <<nextTurn, nextStep, turn, phase, tid, fence, step, active, rows, turnIds, stepIds>>

Next ==
    \/ StartTurn
    \/ \E n \in 1..Calls, before, after, streamed \in BOOLEAN : ToolStep(n, before, after, streamed)
    \/ FinalStep
    \/ StartSubagent

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* What the screen shows under each prompt, for the driver's comparison.   *)

Shown(i) == rows[i].kind = "tool" /\ rows[i].shown
FirstOfKey(i) == ~\E m \in 1..(i - 1) : Shown(m) /\ rows[m].turn = rows[i].turn /\ rows[m].key = rows[i].key

RECURSIVE MembersFrom(_, _, _, _)
MembersFrom(k, key, i, acc) ==
    IF i > Len(rows) THEN acc
    ELSE MembersFrom(k, key, i + 1,
        IF Shown(i) /\ rows[i].turn = k /\ rows[i].key = key
        THEN Append(acc, <<rows[i].turn, rows[i].step, rows[i].call>>) ELSE acc)

Item(kind, k, j, where, calls) == [kind |-> kind, turn |-> k, step |-> j, where |-> where, calls |-> calls]

\* Under prompt k: each text, and each block where its first call lands,
\* holding every call of turn k with its key.
RECURSIVE ScreenFrom(_, _, _)
ScreenFrom(k, i, acc) ==
    IF i > Len(rows) THEN acc
    ELSE LET r == rows[i] IN
        ScreenFrom(k, i + 1,
            IF r.turn /= k THEN acc
            ELSE IF r.kind = "text" THEN Append(acc, Item("text", k, r.step, r.where, <<>>))
            ELSE IF Shown(i) /\ FirstOfKey(i) THEN Append(acc, Item("block", k, 0, "", MembersFrom(k, r.key, 1, <<>>)))
            ELSE acc)

Screen == [k \in 1..turn |-> ScreenFrom(k, 1, <<>>)]

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

TypeOK ==
    /\ phase \in {"idle", "turn"}
    /\ turn \in 0..Turns /\ step \in 0..Steps
    /\ Len(active) <= 1
    /\ \A i \in 1..Len(rows) : rows[i].kind \in {"text", "tool"} /\ rows[i].turn \in 1..Turns

Injective(s) == \A a, b \in 1..Len(s) : a /= b => s[a] /= s[b]

\* Every turn, step, and subagent gets an id of its own.
DistinctIds == Injective(turnIds) /\ Injective(stepIds) /\ Injective(subagentIds)

\* 0 means "no id": trace lines leave it out, and the transcript ignores a
\* call or group that carries it.
IdsNonZero ==
    \A s \in {turnIds, stepIds, subagentIds} : \A i \in 1..Len(s) : s[i] /= 0

\* Every call the model makes shows on the screen.
EveryCallShows == \A i \in 1..Len(rows) : rows[i].kind = "tool" => rows[i].shown

\* Two calls of one turn that have text between them never share a block.
TextSplitsBlocks ==
    \A a, b \in 1..Len(rows) :
        (a < b /\ Shown(a) /\ Shown(b) /\ rows[a].turn = rows[b].turn /\ rows[a].key = rows[b].key)
            => ~\E m \in (a + 1)..(b - 1) : rows[m].kind = "text"
=============================================================================
