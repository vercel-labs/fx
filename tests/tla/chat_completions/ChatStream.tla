------------------------------ MODULE ChatStream ------------------------------
(***************************************************************************)
(* How fx reads one streamed reply on a configured openai-chat-completions *)
(* connection (`Reducer` and `consume_stream` in                           *)
(* src/gateway/chat_completions_protocol.zig), and which replies it must   *)
(* accept.                                                                 *)
(*                                                                         *)
(* The server sends data events, then ends the stream with [DONE], a clean *)
(* close, or a close inside an unterminated last event. The SSE reader     *)
(* (src/gateway/sse.zig) drops an unterminated event, so the reducer reads *)
(* a cut exactly like a clean close before that event.                     *)
(*                                                                         *)
(* `r` is the reducer, deciding each event the way fx does. `o` is the     *)
(* oracle: it describes, without looking at the reducer, the replies a     *)
(* healthy OpenAI-compatible server sends. Such a reply is body chunks,    *)
(* one finished choice, then usage trailers, then the end, where           *)
(*                                                                         *)
(*   - a model name, when one is named, is the same in every chunk; an     *)
(*     empty model names nothing;                                          *)
(*   - a legacy function_call is at most an all-empty placeholder;         *)
(*   - a trailer is `choices: []` or the finished choice again, with       *)
(*     usage, no new content or calls, and the same finish_reason or none; *)
(*   - the end may come without [DONE] once the choice has finished, and a *)
(*     reply that ends before it is truncated;                             *)
(*   - the reason is tool_calls exactly when the reply carried a call.     *)
(*                                                                         *)
(* `o.why` names the first way the stream left that language, or "none".  *)
(* The design (Bug = "none") fails only streams that left it and completes *)
(* only streams that did not. Bug = "today" is fx before the change: an    *)
(* empty model, a placeholder function_call, a close without [DONE], and a *)
(* trailer without finish_reason each failed the turn. Each old_* value is *)
(* one of those rules alone, and each remaining value plants one bug that  *)
(* accepts too much; check.sh lists the rule that must catch each.         *)
(*                                                                         *)
(* ChatStreamTrace.tla replays streams that                                *)
(* tests/tla/drivers/chat_completions/driver.ts sent to the built fx       *)
(* through this module's own actions.                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Bug

OldRules == {"old_model", "old_function_call", "old_eof", "old_reason"}
Mutations == {"eof_any_phase", "skip_models", "accept_call", "late_content", "no_usage", "skip_tools"}
ASSUME Bug \in {"none", "today"} \cup OldRules \cup Mutations

\* Whether fx follows the given rule from before the change.
Old(rule) == Bug = rule \/ (Bug = "today" /\ rule \in OldRules)

(***************************************************************************)
(* Events. A chunk's choice is "none" for `choices: []`, "empty" for a     *)
(* choice with an empty delta, "content" for text, "call" for a tool-call  *)
(* delta, and "stop" or "tools" for a choice with that finish_reason. Only *)
(* those last two carry a finish_reason; the others omit it or send null.  *)
(* `fc` is the delta's legacy function_call: absent, an all-empty          *)
(* placeholder, or one that names something.                               *)
(***************************************************************************)
Choices == {"none", "empty", "content", "call", "stop", "tools"}
Models == {"absent", "empty", "a", "b"}
LegacyCalls == {"none", "empty", "full"}
Ends == {"done", "eof", "cut"}

Chunk(c, m, f, u) == [kind |-> "chunk", choice |-> c, model |-> m, fc |-> f, usage |-> u]
End(k) == [kind |-> k, choice |-> "none", model |-> "absent", fc |-> "none", usage |-> FALSE]

\* `choices: []` has no delta, so it carries no legacy function_call.
Events ==
    ({Chunk(c, m, f, u) : c \in Choices, m \in Models, f \in LegacyCalls, u \in BOOLEAN}
        \ {Chunk("none", m, f, u) : m \in Models, f \in {"empty", "full"}, u \in BOOLEAN})
    \cup {End(k) : k \in Ends}

ReasonOf(choice) == IF choice = "tools" THEN "tool_calls" ELSE "stop"
Named(e) == e.model \in {"a", "b"}

Errors == {"none", "InvalidChunk", "ConflictingIdentity", "InconsistentFinishReason", "IncompleteStream"}
Causes == {"none", "conflict", "early_usage", "legacy_call", "mismatch", "late", "usage", "truncated", "tools",
           "model", "function_call", "eof", "reason"}
Whys == {"none", "conflict", "early_usage", "legacy_call", "mismatch", "late", "usage", "truncated", "tools"}

VARIABLES r, o
vars == <<r, o>>

InitR == [phase |-> "receiving", identity |-> "none", calls |-> FALSE, reason |-> "none",
          outcome |-> "pending", error |-> "none", cause |-> "none"]
InitO == [stage |-> "body", names |-> {}, calls |-> FALSE, reason |-> "none", why |-> "none"]

Init == r = InitR /\ o = InitO

TypeOK ==
    /\ r.phase \in {"receiving", "finished", "closed"}
    /\ r.identity \in {"none", "a", "b"}
    /\ r.calls \in BOOLEAN
    /\ r.reason \in {"none", "stop", "tool_calls"}
    /\ r.outcome \in {"pending", "completed", "failed"}
    /\ r.error \in Errors
    /\ r.cause \in Causes
    /\ o.stage \in {"body", "trailer", "ended"}
    /\ o.names \subseteq {"a", "b"}
    /\ o.calls \in BOOLEAN
    /\ o.reason \in {"none", "stop", "tool_calls"}
    /\ o.why \in Whys

(***************************************************************************)
(* The reducer. Each operator returns the reducer after one event, with    *)
(* the checks in the order the code makes them.                            *)
(***************************************************************************)
Failed(s, err, why) == [s EXCEPT !.phase = "closed", !.outcome = "failed", !.error = err, !.cause = why]
Completed(s) == [s EXCEPT !.phase = "closed", !.outcome = "completed"]

\* Reducer.finish: a finished reply must agree with its tool calls.
Finish(s) ==
    IF (s.reason = "tool_calls") # s.calls /\ Bug # "skip_tools"
    THEN Failed(s, "InconsistentFinishReason", "tools")
    ELSE Completed(s)

\* The first named model is the reply's identity; an empty one names nothing.
WithModel(s, e) ==
    IF Named(e) /\ s.identity = "none" /\ Bug # "skip_models" THEN [s EXCEPT !.identity = e.model] ELSE s

\* A chunk before the finished choice.
Receive(s, e) ==
    IF e.choice = "none" THEN Failed(s, "InvalidChunk", "early_usage")
    ELSE IF e.fc = "full" /\ Bug # "accept_call" THEN Failed(s, "InvalidChunk", "legacy_call")
    ELSE IF e.fc = "empty" /\ Old("old_function_call") THEN Failed(s, "InvalidChunk", "function_call")
    ELSE IF e.choice = "call" THEN [s EXCEPT !.calls = TRUE]
    ELSE IF e.choice \in {"stop", "tools"} THEN [s EXCEPT !.phase = "finished", !.reason = ReasonOf(e.choice)]
    ELSE s

\* A chunk after it: usage, or the finished choice repeated with usage.
Trailer(s, e) ==
    IF e.choice = "none" THEN (IF e.usage THEN s ELSE Failed(s, "InvalidChunk", "usage"))
    ELSE IF e.choice \in {"stop", "tools"} /\ ReasonOf(e.choice) # s.reason
        THEN Failed(s, "InconsistentFinishReason", "mismatch")
    ELSE IF e.choice \notin {"stop", "tools"} /\ Old("old_reason")
        THEN Failed(s, "InconsistentFinishReason", "reason")
    ELSE IF e.choice \in {"content", "call"} /\ Bug # "late_content"
        THEN Failed(s, "InconsistentFinishReason", "late")
    ELSE IF e.fc = "full" /\ Bug # "accept_call" THEN Failed(s, "InconsistentFinishReason", "legacy_call")
    ELSE IF e.fc = "empty" /\ Old("old_function_call") THEN Failed(s, "InconsistentFinishReason", "function_call")
    ELSE IF ~e.usage /\ Bug # "no_usage" THEN Failed(s, "InconsistentFinishReason", "usage")
    ELSE s

ReduceChunk(s, e) ==
    IF Named(e) /\ s.identity \notin {"none", e.model} /\ Bug # "skip_models"
        THEN Failed(s, "ConflictingIdentity", "conflict")
    ELSE IF e.model = "empty" /\ Old("old_model") THEN Failed(s, "InvalidChunk", "model")
    ELSE IF s.phase = "receiving" THEN Receive(WithModel(s, e), e)
    ELSE Trailer(WithModel(s, e), e)

\* [DONE] ends a finished reply. A close, or a cut the reader drops, ends it
\* too, unless fx still waits for [DONE].
ReduceEnd(s, e) ==
    IF e.kind = "done" THEN (IF s.phase = "finished" THEN Finish(s) ELSE Failed(s, "IncompleteStream", "truncated"))
    ELSE IF s.phase = "finished" THEN
        (IF Old("old_eof") THEN Failed(s, "IncompleteStream", "eof") ELSE Finish(s))
    ELSE IF Bug = "eof_any_phase" THEN Completed(s)
    ELSE Failed(s, "IncompleteStream", "truncated")

Reduce(s, e) == IF e.kind = "chunk" THEN ReduceChunk(s, e) ELSE ReduceEnd(s, e)

(***************************************************************************)
(* The oracle: what a healthy server can have sent so far.                 *)
(***************************************************************************)
Departs(s, e) ==
    IF Named(e) /\ s.names \ {e.model} # {} THEN "conflict"
    ELSE IF e.fc = "full" THEN "legacy_call"
    ELSE IF s.stage = "body" THEN (IF e.choice = "none" THEN "early_usage" ELSE "none")
    ELSE IF e.choice \in {"content", "call"} THEN "late"
    ELSE IF e.choice \in {"stop", "tools"} /\ ReasonOf(e.choice) # s.reason THEN "mismatch"
    ELSE IF ~e.usage THEN "usage"
    ELSE "none"

HearChunk(s, e) ==
    [s EXCEPT
        !.names = IF Named(e) THEN s.names \cup {e.model} ELSE s.names,
        !.calls = s.calls \/ (s.stage = "body" /\ e.choice = "call"),
        !.stage = IF s.stage = "body" /\ e.choice \in {"stop", "tools"} THEN "trailer" ELSE s.stage,
        !.reason = IF s.stage = "body" /\ e.choice \in {"stop", "tools"} THEN ReasonOf(e.choice) ELSE s.reason,
        !.why = IF s.why = "none" THEN Departs(s, e) ELSE s.why]

\* A cut drops the event it interrupted, so it ends the stream where the last
\* whole event did: a reply cut inside a trailer is whole, with the usage
\* seen so far.
HearEnd(s) ==
    [s EXCEPT
        !.stage = "ended",
        !.why = IF s.why # "none" THEN s.why
                ELSE IF s.stage = "body" THEN "truncated"
                ELSE IF (s.reason = "tool_calls") # s.calls THEN "tools"
                ELSE "none"]

Hear(s, e) == IF e.kind = "chunk" THEN HearChunk(s, e) ELSE HearEnd(s)

(***************************************************************************)
(* The server sends one event at a time until it ends the stream or fx     *)
(* stops reading.                                                          *)
(***************************************************************************)
Send(e) ==
    /\ o.stage # "ended"
    /\ r.outcome = "pending"
    /\ r' = Reduce(r, e)
    /\ o' = Hear(o, e)

\* A decided reply stays decided.
Decided == r.outcome # "pending" /\ UNCHANGED vars

Next == (\E e \in Events : Send(e)) \/ Decided

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Rules                                                                   *)
(***************************************************************************)
Benign == o.why = "none"

\* fx fails a reply only when the server left the language.
BenignNeverFails == r.outcome = "failed" => ~Benign

\* fx completes a reply only when the server stayed in it.
OnlyBenignCompletes == r.outcome = "completed" => Benign

\* Once the stream ends, the reply is decided.
EndDecides == o.stage = "ended" => r.outcome # "pending"

\* BenignNeverFails, named for each rule fx had before the change.
FailedBenignBy(rule) == r.outcome = "failed" /\ Benign /\ r.cause = rule
EmptyModelAccepted == ~FailedBenignBy("model")
PlaceholderAccepted == ~FailedBenignBy("function_call")
EndAfterFinishCompletes == ~FailedBenignBy("eof")
TrailerReasonOptional == ~FailedBenignBy("reason")

\* OnlyBenignCompletes, named for each way a stream can leave the language.
CompletedDespite(why) == r.outcome = "completed" /\ o.why = why
IdentityHeld == ~CompletedDespite("conflict")
LegacyCallRefused == ~CompletedDespite("legacy_call")
CutStreamsFail == ~CompletedDespite("truncated")
TrailerCarriesNoContent == ~CompletedDespite("late")
TrailerCarriesUsage == ~CompletedDespite("usage")
ToolsMatchReason == ~CompletedDespite("tools")
=============================================================================
