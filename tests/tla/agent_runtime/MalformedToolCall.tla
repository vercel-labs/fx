-------------------------- MODULE MalformedToolCall --------------------------
(***************************************************************************)
(* What one fx turn does after each model reply, for the feedback after a  *)
(* tool call the provider could not read, in                               *)
(* src/core/agent/runtime/orchestrator.zig.                                *)
(*                                                                         *)
(* Gemini ends a reply with MALFORMED_FUNCTION_CALL when it cannot write   *)
(* a valid function call, and the AI SDK reports the finish `error`. fx    *)
(* used to treat that as a server failure: it waited the backoff and sent  *)
(* the same request again, with no limit. After a failed reply that        *)
(* started a web search it also sent the resend with tools off, which      *)
(* Gemini answers with MALFORMED_FUNCTION_CALL again. Now fx tells the     *)
(* model at once, with tools on, that its call could not be read and did   *)
(* not run; a second malformed reply in the same step gets a stronger      *)
(* hint, and a third ends the turn as failed. A failed reply that started  *)
(* a search, which only reads, resends with tools on. A malformed reply to *)
(* a resend with tools off stops the turn for review.                      *)
(*                                                                         *)
(* A reply is one of:                                                      *)
(*   "tool"            a valid local tool call, which fx runs              *)
(*   "text"            a final answer                                      *)
(*   "malformed"       a local tool call, then MALFORMED_FUNCTION_CALL     *)
(*   "malformed_bare"  MALFORMED_FUNCTION_CALL with no call and no text    *)
(*   "search_failed"   a provider search start, then a provider error      *)
(*   "transient"       a provider error with no call: a server failure     *)
(*   "unsafe_failed"   a provider error after a provider tool start that   *)
(*                     does not only read, so whether it ran is unknown    *)
(* Each request carries one of:                                            *)
(*   "prompt"      the user's prompt (the first request)                   *)
(*   "tools"       the results of the reply's tool calls                   *)
(*   "feedback1"   the first malformed-call feedback of the step           *)
(*   "feedback2"   the second one, which asks for smaller calls            *)
(*   "resend"      the same request again                                  *)
(*   "regenerate"  the request with "fx did not execute that call"         *)
(*   "search"      the request with the note that a search may have run    *)
(*   "reconcile"   the request with tools off and the reconcile prompt     *)
(* and goes with tools on or off, right away or after the backoff.         *)
(*                                                                         *)
(* limit is the step limit (FX_MAX_AGENT_STEPS), 0 for none. A step starts *)
(* with a request that carries "prompt" or "tools", and fx may start step  *)
(* n + 1 only when limit = 0 or n < limit                                  *)
(* (src/core/config/agent_steps.zig allowsStep). Feedback and resends stay *)
(* in their step.                                                          *)
(*                                                                         *)
(* evidence is what the step's failed attempts showed about tool calls,    *)
(* as src/core/agent/runtime/resend_strategy.zig names it, and picks how a *)
(* resend after a server failure is phrased.                               *)
(*                                                                         *)
(* ReplyKinds limits the replies a config explores. Bug plants one defect; *)
(* check.sh names the rule that must catch each, and Bug = "today" is fx   *)
(* before the change.                                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Limits, MaxRequests, ReplyKinds, Bug

Kinds == {"tool", "text", "malformed", "malformed_bare", "search_failed", "transient", "unsafe_failed"}
Malformed == {"malformed", "malformed_bare"}
ServerFailures == {"transient", "search_failed", "unsafe_failed"}
\* Replies that stream a tool call or a tool start before they end.
ToolStarts == {"tool", "malformed", "search_failed", "unsafe_failed"}
Carries == {"prompt", "tools", "feedback1", "feedback2", "resend", "regenerate", "search", "reconcile"}
Feedback == {"feedback1", "feedback2"}
StepStarts == {"prompt", "tools"}
Evidences == {"none", "unexecuted", "repeatable", "uncertain"}
Outcomes == {"none", "answered", "failed_malformed", "review", "step_limit"}

ASSUME ReplyKinds \subseteq Kinds

VARIABLES
    phase,     \* "waiting" for a reply, or "done"
    limit,     \* the turn's step limit, 0 for none
    steps,     \* steps started so far
    count,     \* malformed replies so far in this step
    evidence,  \* what this step's failed attempts showed about tool calls
    sent,      \* what each request carried, in order
    tools,     \* whether each request went with tools on
    waited,    \* whether fx waited the backoff before each request
    replies,   \* each reply, in order; replies[i] answers sent[i]
    ran,       \* whether fx ran each reply's tool calls
    outcome    \* how the turn ended

vars == <<phase, limit, steps, count, evidence, sent, tools, waited, replies, ran, outcome>>

InitWith(l) ==
    /\ phase = "waiting"
    /\ limit = l
    /\ steps = 1
    /\ count = 0
    /\ evidence = "none"
    /\ sent = <<"prompt">>
    /\ tools = <<TRUE>>
    /\ waited = <<FALSE>>
    /\ replies = <<>>
    /\ ran = <<>>
    /\ outcome = "none"

Init == \E l \in Limits : InitWith(l)

\* A fresh turn, for trace validation of several runs in a row.
Reset(l) ==
    /\ phase' = "waiting"
    /\ limit' = l
    /\ steps' = 1
    /\ count' = 0
    /\ evidence' = "none"
    /\ sent' = <<"prompt">>
    /\ tools' = <<TRUE>>
    /\ waited' = <<FALSE>>
    /\ replies' = <<>>
    /\ ran' = <<>>
    /\ outcome' = "none"

\* The request the current reply answers.
Answered == sent[Len(sent)]

\* fx may start another step.
AllowsStep == limit = 0 \/ steps < limit

Send(carry, on, wait) ==
    /\ sent' = Append(sent, carry)
    /\ tools' = Append(tools, on)
    /\ waited' = Append(waited, wait)
    /\ phase' = "waiting"
    /\ UNCHANGED outcome

Finish(o) ==
    /\ phase' = "done"
    /\ outcome' = o
    /\ UNCHANGED <<sent, tools, waited>>

\* A resend after a server failure waits the backoff, and its phrasing
\* follows the evidence (resend_strategy.select): only "reconcile" goes with
\* tools off.
Resend(e) ==
    CASE e = "none" -> Send("resend", TRUE, TRUE)
      [] e = "unexecuted" -> Send("regenerate", TRUE, TRUE)
      [] e = "repeatable" -> Send("search", TRUE, TRUE)
      [] e = "uncertain" -> Send("reconcile", FALSE, TRUE)

\* What a provider search start leaves: it only reads, so a second search is
\* safe. search_reconcile, and fx before the change, treat it as unknown.
SearchEvidence == IF Bug \in {"search_reconcile", "today"} THEN "uncertain" ELSE "repeatable"

\* fx runs a reply's calls and starts the next step. no_reset: the malformed
\* count survives a step that made progress.
RunTools ==
    /\ evidence' = "none"
    /\ count' = IF Bug = "no_reset" THEN count ELSE 0
    /\ IF AllowsStep
         THEN /\ steps' = steps + 1
              /\ Send("tools", TRUE, FALSE)
         ELSE /\ UNCHANGED steps
              /\ Finish("step_limit")

\* The feedback for the n-th malformed reply of a step. backoff: it waits.
\* tools_off: it goes with tools off.
SendFeedback(n) ==
    Send(IF n = 1 THEN "feedback1" ELSE "feedback2", Bug # "tools_off", Bug = "backoff")

MalformedReply(k) ==
    /\ UNCHANGED steps
    /\ IF Answered = "reconcile"
         \* Only a bare one gets here (Reply): the model wanted a tool while
         \* tools were off. reconcile_loop, and fx before the change, send
         \* the reconcile request again.
         THEN IF Bug \in {"reconcile_loop", "today"}
                THEN /\ UNCHANGED <<count, evidence>>
                     /\ Resend(evidence)
                ELSE /\ UNCHANGED <<count, evidence>>
                     /\ Finish("review")
       ELSE IF Bug = "today"
         \* fx before the change: a server failure. A streamed local call
         \* is proven unexecuted (PR #1857); a bare reply shows nothing.
         THEN /\ UNCHANGED count
              /\ evidence' = IF k = "malformed" THEN "unexecuted" ELSE evidence
              /\ Resend(evidence')
       ELSE IF Bug = "run_call" /\ k = "malformed"
         THEN RunTools
       ELSE /\ count' = count + 1
            /\ evidence' = IF k = "malformed" THEN "unexecuted" ELSE evidence
            /\ IF count + 1 <= 2 \/ Bug = "no_cap"
                 THEN SendFeedback(IF count + 1 > 2 THEN 2 ELSE count + 1)
                 ELSE Finish("failed_malformed")

ServerFailure(k) ==
    /\ UNCHANGED <<steps, count>>
    /\ evidence' = CASE k = "transient" -> evidence
                     [] k = "search_failed" -> SearchEvidence
                     [] k = "unsafe_failed" -> "uncertain"
    /\ Resend(evidence')

\* fx runs the calls of a valid tool reply that does not answer a request
\* with tools off, also when no step is left after it. run_call: it runs a
\* malformed reply's streamed call too.
Runs(k) ==
    /\ ~(Answered = "reconcile" /\ k \in ToolStarts)
    /\ k = "tool" \/ (k = "malformed" /\ Bug = "run_call")

Reply(k) ==
    /\ phase = "waiting"
    /\ replies' = Append(replies, k)
    /\ ran' = Append(ran, Runs(k))
    /\ UNCHANGED limit
    /\ IF Answered = "reconcile" /\ k \in ToolStarts
         \* A tool call or start while tools are off ends the turn for
         \* review, before any resend (orchestrator.zig
         \* uncertain_provider_tool_rejected).
         THEN /\ UNCHANGED <<steps, count, evidence>>
              /\ Finish("review")
         ELSE CASE k = "text" ->
                     /\ UNCHANGED <<steps, count, evidence>>
                     /\ Finish("answered")
                [] k = "tool" -> RunTools
                [] k \in Malformed -> MalformedReply(k)
                [] k \in ServerFailures -> ServerFailure(k)

Ended == phase = "done" /\ UNCHANGED vars

Next == (\E k \in ReplyKinds : Reply(k)) \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in {"waiting", "done"}
    /\ limit \in Limits
    /\ steps \in Nat
    /\ count \in 0..MaxRequests
    /\ evidence \in Evidences
    /\ sent \in Seq(Carries)
    /\ tools \in Seq(BOOLEAN)
    /\ waited \in Seq(BOOLEAN)
    /\ Len(tools) = Len(sent) /\ Len(waited) = Len(sent)
    /\ replies \in Seq(Kinds)
    /\ ran \in Seq(BOOLEAN) /\ Len(ran) = Len(replies)
    /\ outcome \in Outcomes

\* Where the step that holds request i starts.
StepStart(i) ==
    CHOOSE j \in 1..i :
        /\ sent[j] \in StepStarts
        /\ \A m \in (j + 1)..i : sent[m] \notin StepStarts

\* How many malformed replies the step has had up to and including reply i.
MalformedInStep(i) ==
    Cardinality({j \in StepStart(i)..i : replies[j] \in Malformed})

\* A malformed reply's call never runs.
MalformedNeverRuns ==
    \A i \in 1..Len(replies) : replies[i] \in Malformed => ~ran[i]

\* Feedback follows only a malformed reply.
FeedbackOnlyAfterMalformed ==
    \A i \in 2..Len(sent) : sent[i] \in Feedback => replies[i - 1] \in Malformed

\* Feedback goes right away: the provider answered, so there is no server
\* failure to wait out.
FeedbackRightAway ==
    \A i \in 1..Len(sent) : sent[i] \in Feedback => ~waited[i]

\* Feedback keeps tools on, so the model can make the call again.
FeedbackKeepsTools ==
    \A i \in 1..Len(sent) : sent[i] \in Feedback => tools[i]

\* A server failure still waits the backoff before the resend
\* (tests/tla/recovery/Recovery.tla NoHotRetry).
ServerFailuresWait ==
    \A i \in 2..Len(sent) : replies[i - 1] \in ServerFailures => waited[i]

\* A failed reply that started a search keeps tools on for the resend.
SearchKeepsTools ==
    \A i \in 1..Len(replies) :
        (replies[i] = "search_failed" /\ Len(sent) > i) => tools[i + 1]

\* A malformed reply to a request with tools off stops the turn for review.
ReconcileMalformedStops ==
    \A i \in 1..Len(replies) :
        (replies[i] \in Malformed /\ sent[i] = "reconcile")
            => (Len(sent) = i /\ outcome = "review")

\* The first and second malformed replies of a step each get their feedback:
\* separate stalls in one long turn each start again at the first.
EveryStallGetsFeedback ==
    \A i \in 1..Len(replies) :
        (/\ replies[i] \in Malformed
         /\ sent[i] # "reconcile"
         /\ MalformedInStep(i) <= 2)
            => (/\ Len(sent) > i
                /\ sent[i + 1] = IF MalformedInStep(i) = 1 THEN "feedback1" ELSE "feedback2")

\* The third malformed reply of a step ends the turn as failed: fx never
\* sends a third feedback.
EndsAfterThird ==
    \A i \in 1..Len(replies) :
        (/\ replies[i] \in Malformed
         /\ sent[i] # "reconcile"
         /\ MalformedInStep(i) >= 3)
            => (Len(sent) = i /\ outcome = "failed_malformed")

\* The turn never starts more steps than its limit.
StepsBounded == limit # 0 => steps <= limit
=============================================================================
