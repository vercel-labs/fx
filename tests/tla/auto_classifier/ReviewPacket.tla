---------------------------- MODULE ReviewPacket ----------------------------
(***************************************************************************)
(* What one automatic permission review sends to its provider, and what    *)
(* the reviewer's model context holds once the provider has read it        *)
(* (src/core/permissions/auto_classifier.zig Reviewer.review and its       *)
(* reviewer edges: src/gateway/chat_completions.zig build_review,          *)
(* src/gateway/responses_permission_reviewer.zig for Codex and Grok, and   *)
(* src/builtins/gateway/permission_reviewer.zig for the Gateway).          *)
(*                                                                         *)
(* The core composes the instruction, which carries the normalized action, *)
(* then the user context and the pending assistant call, with the call's   *)
(* provider replay, its reasoning, cleared. Each edge turns that into its  *)
(* wire packet. A Chat Completions endpoint in DeepSeek's thinking mode    *)
(* requires reasoning on every earlier assistant message of a request that *)
(* carries tools: when one is missing it may restore the reasoning from    *)
(* the tool-call ID, or it answers 400. It makes that choice per request,  *)
(* which is why the failure is intermittent.                               *)
(*                                                                         *)
(* Design selects the composition:                                         *)
(*   "text_only"       the chat edge sends only the instruction and the    *)
(*                     user context                                        *)
(*   "today"           every edge sends the pending call and a             *)
(*                     placeholder tool result                             *)
(*   "placeholder"     the chat edge writes an empty reasoning_content on  *)
(*                     the pending call                                    *)
(*   "replay"          the core forwards the call's real reasoning         *)
(*   "core_text_only"  the core drops the pending call for every provider  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Providers,       \* a subset of {"gateway", "codex", "grok", "chat"}
    ChatEndpoints,   \* a subset of {"deepseek", "plain"}
    RestoreChoices,  \* a subset of BOOLEAN: may a DeepSeek endpoint restore omitted reasoning
    EmptyChoices,    \* a subset of BOOLEAN: does it count an empty reasoning_content as passed back
    Design

Shared == {"gateway", "codex", "grok"}
Answers == {"clear", "caution"}
Verdicts == {"accepted", "restored", "rejected"}
Outcomes == {"none", "ran", "held_caution", "held_unavailable"}
Phases == {"pending", "send", "answer", "decide", "done"}
Roles == {"system", "user", "assistant", "tool"}
Reasoning == {"none", "empty", "real"}
Facts == {"action", "root", "call_id", "placeholder", "reasoning"}

Msg(role, r) == [role |-> role, reasoning |-> r]
Instruction == Msg("system", "none")
UserContext == Msg("user", "none")
PendingCall(r) == Msg("assistant", r)
Placeholder == Msg("tool", "none")

\* The core's review messages (auto_classifier.zig Reviewer.review): the
\* instruction lane, the user context, and the pending call with its
\* provider replay cleared.
CorePacket ==
    CASE Design = "replay" -> <<Instruction, UserContext, PendingCall("real")>>
      [] Design = "core_text_only" -> <<Instruction, UserContext>>
      [] OTHER -> <<Instruction, UserContext, PendingCall("none")>>

HasCall(p) == \E i \in DOMAIN p : p[i].role = "assistant"

\* vercel_protocol.zig expandPendingToolReviewMessages closes the pending
\* call with a placeholder result. The Gateway, Codex, and Grok edges use it.
Expand(p) == IF HasCall(p) THEN Append(p, Placeholder) ELSE p

EmptyReasoning(p) ==
    [i \in DOMAIN p |->
        IF p[i].role = "assistant" THEN [p[i] EXCEPT !.reasoning = "empty"] ELSE p[i]]

\* The design's Chat Completions edge (chat_completions.zig build_review
\* through vercel_protocol.zig pendingToolReviewContext): the pending call and
\* its placeholder result stay out of the request, so no assistant message and
\* no tool-call ID reach the endpoint. The exact action and its call ID still
\* travel as text in the instruction.
WithoutCall(p) == SelectSeq(p, LAMBDA m : m.role \notin {"assistant", "tool"})

\* The packet each edge sends.
PacketFor(provider) ==
    IF provider \in Shared THEN Expand(CorePacket)
    ELSE CASE Design = "text_only" -> WithoutCall(CorePacket)
           [] Design = "placeholder" -> Expand(EmptyReasoning(CorePacket))
           [] OTHER -> Expand(CorePacket)

\* What the shared edges sent before the change and must keep sending.
TodayPacket == <<Instruction, UserContext, PendingCall("none"), Placeholder>>

\* What one message puts in the reviewer's model context.
Holds(m) ==
    CASE m.role = "system" -> {"action"}
      [] m.role = "user" -> {"root"}
      [] m.role = "assistant" -> {"call_id"} \cup (IF m.reasoning = "real" THEN {"reasoning"} ELSE {})
      [] m.role = "tool" -> {"placeholder"}

Contents(p) == UNION {Holds(p[i]) : i \in DOMAIN p}

VARIABLES provider, endpoint, emptyPassed, phase, packet, served, answers, context, outcome
vars == <<provider, endpoint, emptyPassed, phase, packet, served, answers, context, outcome>>

Omitted(m) ==
    /\ m.role = "assistant"
    /\ \/ m.reasoning = "none"
       \/ m.reasoning = "empty" /\ ~emptyPassed

\* The endpoint's verdict on one request.
Verdict(p, restore) ==
    IF endpoint = "deepseek" /\ \E i \in DOMAIN p : Omitted(p[i])
    THEN IF restore THEN "restored" ELSE "rejected"
    ELSE "accepted"

Delivered(p, v) ==
    CASE v = "rejected" -> {}
      [] v = "restored" -> Contents(p) \cup {"reasoning"}
      [] OTHER -> Contents(p)

InitWith(p, e, empty) ==
    /\ provider = p
    /\ endpoint = e
    /\ emptyPassed = empty
    /\ phase = "pending"
    /\ packet = <<>>
    /\ served = <<>>
    /\ answers = <<>>
    /\ context = {}
    /\ outcome = "none"

Init ==
    \E p \in Providers, empty \in EmptyChoices :
        \E e \in (IF p = "chat" THEN ChatEndpoints ELSE {"plain"}) : InitWith(p, e, empty)

\* fx composes the review once; a confirming review resends the same body.
Compose ==
    /\ phase = "pending"
    /\ packet' = PacketFor(provider)
    /\ phase' = "send"
    /\ UNCHANGED <<provider, endpoint, emptyPassed, served, answers, context, outcome>>

Serve(restore) ==
    /\ phase = "send"
    /\ restore \in RestoreChoices
    /\ LET v == Verdict(packet, restore) IN
        /\ served' = Append(served, v)
        /\ context' = context \cup Delivered(packet, v)
        /\ phase' = IF v = "rejected" THEN "decide" ELSE "answer"
    /\ UNCHANGED <<provider, endpoint, emptyPassed, packet, answers, outcome>>

\* The reviewer's decision. A caution here is one that passed fx's quote check.
Answer(a) ==
    /\ phase = "answer"
    /\ a \in Answers
    /\ answers' = Append(answers, a)
    /\ phase' = "decide"
    /\ UNCHANGED <<provider, endpoint, emptyPassed, packet, served, context, outcome>>

\* auto_classifier.zig decide and confirmCaution. A 400 is a permanent
\* transport failure and holds the action as unavailable. A caution is
\* confirmed by one fresh review of the same request, and the hold stands
\* unless that review clears.
Decide ==
    /\ phase = "decide"
    /\ LET answered == served[Len(served)] # "rejected"
           cleared == answered /\ answers[Len(answers)] = "clear"
       IN IF Len(served) = 1
          THEN IF ~answered
               THEN (outcome' = "held_unavailable" /\ phase' = "done")
               ELSE IF cleared
                    THEN (outcome' = "ran" /\ phase' = "done")
                    ELSE (phase' = "send" /\ outcome' = outcome)
          ELSE (outcome' = IF cleared THEN "ran" ELSE "held_caution") /\ phase' = "done"
    /\ UNCHANGED <<provider, endpoint, emptyPassed, packet, served, answers, context>>

Next ==
    \/ Compose
    \/ \E r \in BOOLEAN : Serve(r)
    \/ \E a \in Answers : Answer(a)
    \/ Decide

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK ==
    /\ provider \in Providers
    /\ endpoint \in ChatEndpoints \cup {"plain"}
    /\ emptyPassed \in BOOLEAN
    /\ phase \in Phases
    /\ \A i \in DOMAIN packet : packet[i].role \in Roles /\ packet[i].reasoning \in Reasoning
    /\ \A i \in DOMAIN served : served[i] \in Verdicts
    /\ Len(served) <= 2
    /\ \A i \in DOMAIN answers : answers[i] \in Answers
    /\ context \subseteq Facts
    /\ outcome \in Outcomes

\* No review request is refused for reasoning it does not carry.
ReviewNeverRejected == \A i \in DOMAIN served : served[i] # "rejected"

\* The reviewer never holds the main agent's reasoning, whether fx sent it or
\* the endpoint restored it from a tool-call ID.
NoReasoningToReviewer == "reasoning" \notin context

\* An action runs only after a review cleared it.
RunsOnlyAfterClear == outcome = "ran" => \E i \in DOMAIN answers : answers[i] = "clear"

\* A review that reached the reviewer carried the exact normalized action.
ExactActionReviewed == Len(answers) > 0 => "action" \in context

\* The Gateway, Codex, and Grok edges send what they sent before.
SharedPacketsUnchanged == (provider \in Shared /\ phase # "pending") => packet = TodayPacket
=============================================================================
