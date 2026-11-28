---------------------------- MODULE OutputLimit ----------------------------
(***************************************************************************)
(* What one fx turn does after a model reply cut off at its output limit,  *)
(* in src/core/agent/runtime/orchestrator.zig, with the decision in        *)
(* src/core/agent/runtime/output_limit.zig.                                *)
(*                                                                         *)
(* A provider stops a reply at the output limit, mid-call or after it. fx  *)
(* used to drop every call in such a reply and end the turn as failed, so  *)
(* a subagent stopped and waited for someone to send its task again. Now   *)
(* fx runs the calls that are whole, finished with another call started    *)
(* after them, never a call the cut left unfinished or the call that       *)
(* started last, and tells the model in the same turn what was cut, so it  *)
(* can go on in smaller steps: the note follows the results when calls     *)
(* ran, or goes alone when none did. The first cut that fx goes on from    *)
(* raises a limit fx chose itself for the rest of the turn. Two notes in a *)
(* row are the most: the third cut reply in a row ends the turn as failed, *)
(* and a step that was not cut starts the count again.                     *)
(*                                                                         *)
(* A reply cut before any tool call used to end the turn as completed,     *)
(* with its cut text or a stand-in, so a subagent's parent read a success  *)
(* with no work done. Now its text stays in the turn and the model goes on *)
(* from where it stopped; a reply with no text spent its limit thinking,   *)
(* and the model is asked to take a smaller step. The reply that finishes  *)
(* the answer joins every part since the last tool activity.               *)
(*                                                                         *)
(* A reply is one of:                                                      *)
(*   "tool"          a finished reply with a valid tool call, which fx runs *)
(*   "text"          a final answer                                        *)
(*   "cut_complete"  cut off after a complete call, with a call left cut   *)
(*   "cut_only"      cut off while its only call was unfinished            *)
(*   "cut_closed"    cut off right after its only call: no call started    *)
(*                   after it, so fx cannot tell it from one the limit     *)
(*                   stopped, and it counts as cut                         *)
(*   "cut_bad_id"    cut off after calls that fail the identity checks a   *)
(*                   finished reply's calls pass, such as an empty id      *)
(*   "cut_text"      cut off while it wrote text, before any tool call     *)
(*   "cut_empty"     cut off before any text or tool call: only thinking   *)
(* Each request carries one of:                                            *)
(*   "prompt"          the user's prompt (the first request)               *)
(*   "tools"           the results of the reply's tool calls               *)
(*   "ran_note"        the complete calls' results, then the note          *)
(*   "ran_note_again"  the same, after a cut reply just before it          *)
(*   "note"            the note alone: nothing ran                         *)
(*   "note_again"      the same, after a cut reply just before it          *)
(*   "text_note"       the cut reply's text, then the note to go on from it *)
(*   "text_note_again" the same, after a cut reply just before it          *)
(* and asks for fx's own limit or the raised one (big). answer counts the  *)
(* replies whose text the final answer holds.                              *)
(*                                                                         *)
(* limit is the step limit (FX_MAX_AGENT_STEPS), 0 for none. fx may start  *)
(* step n + 1 only when limit = 0 or n < limit                             *)
(* (src/core/config/agent_steps.zig allowsStep). A note alone starts a     *)
(* step of its own; calls that run do so also when no step is left after   *)
(* them, as a finished tool reply's do.                                    *)
(*                                                                         *)
(* ReplyKinds limits the replies a config explores. Bug plants one defect; *)
(* check.sh names the rule that must catch each, and Bug = "today" is fx   *)
(* before the change.                                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Limits, MaxRequests, ReplyKinds, Bug

Kinds == {"tool", "text", "cut_complete", "cut_only", "cut_closed", "cut_bad_id", "cut_text", "cut_empty"}
Cuts == {"cut_complete", "cut_only", "cut_closed", "cut_bad_id", "cut_text", "cut_empty"}
\* Cut replies with no call fx may run.
NothingToRun == {"cut_only", "cut_closed", "cut_bad_id", "cut_text", "cut_empty"}
\* Replies with tool calls, whole or cut: each ends an answer cut replies began.
ToolActivity == {"tool", "cut_complete", "cut_only", "cut_closed", "cut_bad_id"}
Carries == {"prompt", "tools", "ran_note", "ran_note_again", "note", "note_again", "text_note", "text_note_again"}
Notes == {"ran_note", "ran_note_again", "note", "note_again", "text_note", "text_note_again"}
Outcomes == {"none", "answered", "failed_cut", "step_limit"}
\* output_limit.max_notes_in_a_row
MaxNotes == 2

ASSUME ReplyKinds \subseteq Kinds

VARIABLES
    phase,    \* "waiting" for a reply, or "done"
    limit,    \* the turn's step limit, 0 for none
    steps,    \* steps started so far
    cuts,     \* cut replies in a row so far
    sent,     \* what each request carried, in order
    big,      \* whether each request asked for the raised limit
    replies,  \* each reply, in order; replies[i] answers sent[i]
    ran,      \* whether fx ran calls of each reply
    parts,    \* cut replies' texts since the last tool activity
    answer,   \* the replies whose text the final answer holds, 0 until it ends
    outcome   \* how the turn ended

vars == <<phase, limit, steps, cuts, sent, big, replies, ran, parts, answer, outcome>>

InitWith(l) ==
    /\ phase = "waiting"
    /\ limit = l
    /\ steps = 1
    /\ cuts = 0
    /\ sent = <<"prompt">>
    /\ big = <<FALSE>>
    /\ replies = <<>>
    /\ ran = <<>>
    /\ parts = 0
    /\ answer = 0
    /\ outcome = "none"

Init == \E l \in Limits : InitWith(l)

\* A fresh turn, for trace validation of several runs in a row.
Reset(l) ==
    /\ phase' = "waiting"
    /\ limit' = l
    /\ steps' = 1
    /\ cuts' = 0
    /\ sent' = <<"prompt">>
    /\ big' = <<FALSE>>
    /\ replies' = <<>>
    /\ ran' = <<>>
    /\ parts' = 0
    /\ answer' = 0
    /\ outcome' = "none"

\* fx may start another step.
AllowsStep == limit = 0 \/ steps < limit

\* Whether the turn asks for the raised limit: from the first cut fx went on
\* from. no_raise: it never does.
Raised(after_cut) == IF Bug = "no_raise" THEN FALSE ELSE after_cut \/ big[Len(big)]

Send(carry, b) ==
    /\ sent' = Append(sent, carry)
    /\ big' = Append(big, b)
    /\ phase' = "waiting"
    /\ UNCHANGED <<answer, outcome>>

Finish(o) ==
    /\ phase' = "done"
    /\ outcome' = o
    /\ UNCHANGED <<sent, big, answer>>

\* The turn ends with an answer that holds n replies' text.
Answer(n) ==
    /\ phase' = "done"
    /\ outcome' = "answered"
    /\ answer' = n
    /\ UNCHANGED <<sent, big>>

\* fx runs the reply's calls and starts the next step, or ends the turn at
\* the step limit.
NextStep(carry, b) ==
    IF AllowsStep
      THEN /\ steps' = steps + 1
           /\ Send(carry, b)
      ELSE /\ UNCHANGED steps
           /\ Finish("step_limit")

\* A finished tool reply. no_reset: the cut count survives it.
ToolReply ==
    /\ cuts' = IF Bug = "no_reset" THEN cuts ELSE 0
    /\ NextStep("tools", Raised(FALSE))

\* The cut reply that ends the turn: the notes are spent, or there is nothing
\* to run and no step left.
EndsTurn(k) ==
    \/ cuts >= MaxNotes /\ Bug # "no_cap"
    \/ k \in NothingToRun /\ ~AllowsStep /\ Bug # "ignore_limit"

CutReply(k) ==
    /\ cuts' = cuts + 1
    /\ IF Bug = "today" /\ k \in {"cut_text", "cut_empty"}
         \* fx before the change ended the turn as completed, with the cut
         \* text or a stand-in for it.
         THEN /\ UNCHANGED steps
              /\ Answer(1)
       ELSE IF Bug = "today"
         \* fx before the change dropped every call and ended the turn.
         THEN /\ UNCHANGED steps
              /\ Finish("failed_cut")
       ELSE IF EndsTurn(k)
         THEN /\ UNCHANGED steps
              /\ Finish("failed_cut")
       ELSE IF k = "cut_complete"
         THEN NextStep(IF cuts > 0 THEN "ran_note_again" ELSE "ran_note", Raised(TRUE))
       ELSE IF k = "cut_text"
         THEN /\ steps' = steps + 1
              /\ Send(IF cuts > 0 THEN "text_note_again" ELSE "text_note", Raised(TRUE))
       ELSE /\ steps' = steps + 1
            /\ Send(IF cuts > 0 THEN "note_again" ELSE "note", Raised(TRUE))

\* Whether fx runs calls of reply k. run_cut: it runs a cut call too.
Runs(k) ==
    \/ k = "tool"
    \/ k = "cut_complete" /\ Bug # "today" /\ (cuts < MaxNotes \/ Bug = "no_cap")
    \/ k \in NothingToRun /\ Bug = "run_cut"

\* The texts an answer holds after reply k: a cut reply's text joins the
\* answer, and tool activity ends the answer before it.
PartsAfter(k) ==
    CASE k = "cut_text" -> parts + 1
      [] k \in ToolActivity -> 0
      [] OTHER -> parts

Reply(k) ==
    /\ phase = "waiting"
    /\ replies' = Append(replies, k)
    /\ ran' = Append(ran, Runs(k))
    /\ parts' = PartsAfter(k)
    /\ UNCHANGED limit
    /\ CASE k = "text" ->
              /\ UNCHANGED <<steps, cuts>>
              \* drop_parts: the answer keeps only the reply that ended it.
              /\ Answer(IF Bug = "drop_parts" THEN 1 ELSE parts + 1)
         [] k = "tool" -> ToolReply
         [] k \in Cuts -> CutReply(k)

Ended == phase = "done" /\ UNCHANGED vars

Next == (\E k \in ReplyKinds : Reply(k)) \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in {"waiting", "done"}
    /\ limit \in Limits
    /\ steps \in Nat
    /\ cuts \in 0..MaxRequests
    /\ sent \in Seq(Carries)
    /\ big \in Seq(BOOLEAN) /\ Len(big) = Len(sent)
    /\ replies \in Seq(Kinds)
    /\ ran \in Seq(BOOLEAN) /\ Len(ran) = Len(replies)
    /\ parts \in 0..MaxRequests
    /\ answer \in 0..MaxRequests
    /\ outcome \in Outcomes

\* The cut replies in a row that end with reply i.
CutsInARow(i) ==
    CHOOSE m \in 0..i :
        /\ \A x \in (i - m + 1)..i : replies[x] \in Cuts
        /\ (m = i \/ replies[i - m] \notin Cuts)

\* The note fx sends after the cut reply i.
NoteAfter(i) ==
    CASE replies[i] = "cut_complete" ->
           IF CutsInARow(i) > 1 THEN "ran_note_again" ELSE "ran_note"
      [] replies[i] = "cut_text" ->
           IF CutsInARow(i) > 1 THEN "text_note_again" ELSE "text_note"
      [] OTHER -> IF CutsInARow(i) > 1 THEN "note_again" ELSE "note"

\* A call the cut left unfinished, or one that fails the identity checks,
\* never runs.
CutCallNeverRuns ==
    \A i \in 1..Len(replies) : replies[i] \in NothingToRun => ~ran[i]

\* A note follows only a cut reply.
NoteOnlyAfterCut ==
    \A i \in 2..Len(sent) : sent[i] \in Notes => replies[i - 1] \in Cuts

\* Each of the first two cut replies in a row that fx goes on from gets the
\* note that says what ran, right after it.
EveryCutGetsNote ==
    \A i \in 1..Len(replies) :
        (replies[i] \in Cuts /\ CutsInARow(i) <= MaxNotes /\ Len(sent) > i)
            => sent[i + 1] = NoteAfter(i)

\* A cut reply ends the turn only when the notes are spent or nothing can
\* run with no step left: fx never fails a turn it could go on with.
NoNeedlessFailure ==
    outcome = "failed_cut" =>
        LET last == Len(replies) IN
        \/ CutsInARow(last) > MaxNotes
        \/ replies[last] \in NothingToRun /\ limit # 0 /\ steps >= limit

\* The third cut reply in a row ends the turn as failed, with nothing run:
\* fx never sends a third note in a row.
EndsAfterThird ==
    \A i \in 1..Len(replies) :
        (replies[i] \in Cuts /\ CutsInARow(i) > MaxNotes)
            => (Len(sent) = i /\ outcome = "failed_cut" /\ ~ran[i])

\* Every request after the first cut fx went on from asks for the raised
\* limit, and none before it.
RaisedAfterCut ==
    \A i \in 1..Len(sent) :
        big[i] = (\E j \in 1..(i - 1) : replies[j] \in Cuts)

\* The turn never starts more steps than its limit.
StepsBounded == limit # 0 => steps <= limit

\* Only a reply that finished its text ends the turn as answered: a cut
\* reply never reads as a success.
NoFalseSuccess ==
    outcome = "answered" => replies[Len(replies)] = "text"

\* The cut replies with text since the last tool activity before reply n.
TextPartsBefore(n) ==
    LET activity == {j \in 1..(n - 1) : replies[j] \in ToolActivity}
        from == IF activity = {} THEN 1 ELSE (CHOOSE j \in activity : \A x \in activity : x <= j) + 1
    IN Cardinality({j \in from..(n - 1) : replies[j] = "cut_text"})

\* The final answer holds the text of every cut reply that began it, then
\* the reply that finished it.
AnswerHasEveryPart ==
    (outcome = "answered" /\ replies[Len(replies)] = "text")
        => answer = 1 + TextPartsBefore(Len(replies))
=============================================================================
