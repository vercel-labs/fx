----------------------------- MODULE EmptyReply -----------------------------
(***************************************************************************)
(* What one fx turn's step loop does after each model reply, for the       *)
(* empty-reply nudge in src/core/agent/runtime/orchestrator.zig.           *)
(*                                                                         *)
(* The AI SDK folds the Gemini stop reasons it does not list, such as      *)
(* UNEXPECTED_TOOL_CALL, into the finish reason `other`. A reply that      *)
(* stops that way with no text and no tool call used to end the turn with  *)
(* the placeholder "Done.". Now fx asks the model once to continue, and a  *)
(* second empty reply in a row, or one with no step left, ends the turn    *)
(* as failed with a message that names the provider's reason.              *)
(*                                                                         *)
(* A reply is one of:                                                      *)
(*   "tool"         tool calls with text, Gemini's usual shape             *)
(*   "tool_silent"  tool calls with no text                                *)
(*   "text"         a final answer                                         *)
(*   "text_other"   text whose finish reason is other                      *)
(*   "empty_other"  no text and no tool call, finish reason other          *)
(* Each request carries one of:                                            *)
(*   "prompt"       the user's prompt (the first request)                  *)
(*   "tools"        the results of the reply's tool calls                  *)
(*   "nudge"        the empty-reply nudge                                  *)
(*   "summarize"    the older continuation, "Summarize what you just did." *)
(*                                                                         *)
(* limit is the step limit (FX_MAX_AGENT_STEPS), 0 for none: fx may send   *)
(* request n + 1 only when limit = 0 or n < limit                          *)
(* (src/core/config/agent_steps.zig allowsStep).                           *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Limits, MaxRequests, Bug

Kinds == {"tool", "tool_silent", "text", "text_other", "empty_other"}
Carries == {"prompt", "tools", "nudge", "summarize"}
Outcomes == {"none", "answered", "failed_empty", "step_limit", "placeholder"}

VARIABLES
    phase,       \* "waiting" for a reply, or "done"
    limit,       \* the turn's step limit, 0 for none
    nudged,      \* the step loop's flag: the last empty reply was nudged
    silent,      \* tool steps in a row with no text, capped at 2
    summarized,  \* the older continuation was sent this turn
    sent,        \* what each request carried, in order
    replies,     \* each reply, in order; replies[i] answers sent[i]
    outcome      \* how the turn ended

vars == <<phase, limit, nudged, silent, summarized, sent, replies, outcome>>

InitWith(l) ==
    /\ phase = "waiting"
    /\ limit = l
    /\ nudged = FALSE
    /\ silent = 0
    /\ summarized = FALSE
    /\ sent = <<"prompt">>
    /\ replies = <<>>
    /\ outcome = "none"

Init == \E l \in Limits : InitWith(l)

\* A fresh turn, for trace validation of several runs in a row.
Reset(l) ==
    /\ phase' = "waiting"
    /\ limit' = l
    /\ nudged' = FALSE
    /\ silent' = 0
    /\ summarized' = FALSE
    /\ sent' = <<"prompt">>
    /\ replies' = <<>>
    /\ outcome' = "none"

\* fx may send request n + 1.
Allows(n) == limit = 0 \/ n < limit

\* nudge_text: a reply with text that stops for `other` is treated as empty.
Effect(k) == IF Bug = "nudge_text" /\ k = "text_other" THEN "empty_other" ELSE k

Continue(carry) == /\ sent' = Append(sent, carry)
                   /\ phase' = "waiting"
                   /\ UNCHANGED outcome

Finish(o) == /\ phase' = "done"
             /\ outcome' = o
             /\ UNCHANGED sent

\* The older continuation goes first: summarize_first, and fx before the
\* change ("today").
SummarizeFirst ==
    Bug \in {"summarize_first", "today"} /\ silent >= 2 /\ ~summarized /\ Allows(Len(sent))

CanNudge ==
    /\ ~nudged \/ Bug = "double_nudge"
    /\ Allows(Len(sent)) \/ Bug = "ignore_limit"

EmptyReply ==
    /\ UNCHANGED silent
    /\ IF SummarizeFirst
         THEN /\ summarized' = TRUE
              /\ UNCHANGED nudged
              /\ Continue("summarize")
       ELSE IF Bug = "today"
         THEN /\ UNCHANGED <<nudged, summarized>>
              /\ Finish("placeholder")
       ELSE IF CanNudge
         THEN /\ nudged' = TRUE
              /\ UNCHANGED summarized
              /\ Continue("nudge")
       ELSE /\ UNCHANGED <<nudged, summarized>>
            /\ Finish(IF Bug = "placeholder" THEN "placeholder" ELSE "failed_empty")

ToolReply(e) ==
    /\ silent' = IF e = "tool_silent" THEN IF silent < 2 THEN silent + 1 ELSE 2 ELSE 0
    \* no_reset: the flag survives a step that made progress.
    /\ nudged' = (Bug = "no_reset" /\ nudged)
    /\ UNCHANGED summarized
    /\ IF Allows(Len(sent)) THEN Continue("tools") ELSE Finish("step_limit")

Reply(k) ==
    /\ phase = "waiting"
    /\ replies' = Append(replies, k)
    /\ UNCHANGED limit
    /\ LET e == Effect(k) IN
         CASE e \in {"text", "text_other"} ->
                /\ UNCHANGED <<nudged, silent, summarized>>
                /\ Finish("answered")
           [] e \in {"tool", "tool_silent"} -> ToolReply(e)
           [] e = "empty_other" -> EmptyReply

Ended == phase = "done" /\ UNCHANGED vars

Next == (\E k \in Kinds : Reply(k)) \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in {"waiting", "done"}
    /\ limit \in Limits
    /\ nudged \in BOOLEAN
    /\ silent \in 0..2
    /\ summarized \in BOOLEAN
    /\ sent \in Seq(Carries)
    /\ replies \in Seq(Kinds)
    /\ outcome \in Outcomes

\* An empty reply never ends the turn with the "Done." placeholder.
NoPlaceholder == outcome # "placeholder"

\* A nudge follows only a reply with no text and no tool call.
NudgeOnlyAfterEmptyOther ==
    \A i \in 2..Len(sent) : sent[i] = "nudge" => replies[i - 1] = "empty_other"

\* Never two nudges in a row: the reply to a nudge that is empty again ends
\* the turn.
NoDoubleNudge ==
    \A i \in 2..(Len(sent) - 1) : ~(sent[i] = "nudge" /\ sent[i + 1] = "nudge")

\* Every empty reply that did not answer a nudge is nudged when a step is
\* left: separate stops in one long turn each get their own nudge.
EverySeparateEmptyNudged ==
    \A i \in 1..Len(replies) :
        (/\ replies[i] = "empty_other"
         /\ sent[i] # "nudge"
         /\ (limit = 0 \/ i < limit))
            => (Len(sent) > i /\ sent[i + 1] = "nudge")

\* The turn never sends more requests than its step limit.
StepsBounded == limit # 0 => Len(sent) <= limit
=============================================================================
