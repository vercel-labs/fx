--------------------------- MODULE RequestWrapper ---------------------------
(***************************************************************************)
(* What fx does with one tool call whose arguments a model wrapped in a    *)
(* `request` member, for shell, read_tool_result, and subagent. All three  *)
(* are advertised with top-level arguments, and models still send the old  *)
(* wrapper, some of them, such as MiMo, as the JSON text of the object.    *)
(*                                                                         *)
(* fx reads a wrapper's value with tool_args.requestWrapperObject          *)
(* (src/core/tooling/tool_args.zig): the object itself, or the object its  *)
(* JSON text names when the text is at most max_request_text_bytes long    *)
(* and nests objects and arrays at most MaxDepth levels deep, the limit    *)
(* fx puts on JSON a provider sends (src/core/shared/json_depth.zig).      *)
(* Shell and subagent calls are unwrapped when they arrive, only when      *)
(* `request` is the call's one member (normalized_terminal_request_        *)
(* arguments and normalized_subagent_request_arguments in                  *)
(* src/core/agent/runtime/orchestrator.zig), so admission, permission      *)
(* review, and the saved call all see the flat call, and a wrapper with    *)
(* fields beside it reaches the tool as sent. A subagent call is unwrapped *)
(* for every action the tool takes (subagent_model_contract.Action), and   *)
(* an object wrapper that intake leaves as sent is still read by the       *)
(* tool's own decoder, while its text form is not. read_tool_result's      *)
(* decoder reads `request` whenever it is present                          *)
(* (src/tools/session/read_tool_result.zig), and its history replay        *)
(* unwraps only an exact wrapper (projected_read_tool_result_arguments).   *)
(*                                                                         *)
(* The decoded object is written back out as JSON text, which              *)
(* std.json.Stringify aborts past 256 levels in a safe build. `encoded`    *)
(* is the nesting depth of the last value fx gave that encoder, and the    *)
(* limit keeps it at MaxDepth or less.                                     *)
(*                                                                         *)
(* A call's shape is one of:                                               *)
(*   "flat"             top-level arguments, no wrapper                    *)
(*   "object"           {"request":{...}}                                  *)
(*   "text"             {"request":"<JSON text of an object>"}             *)
(*   "text_nested"      the same, whose object nests MaxDepth levels,      *)
(*                      with a value no tool takes in a string field       *)
(*   "text_deep"        the same, nested more than MaxDepth levels         *)
(*   "text_oversized"   the text of a call, longer than the bound          *)
(*   "text_not_object"  {"request":"<text that is not an object>"}         *)
(*   "object_sibling"   {"request":{...},"<field>":...}                    *)
(*   "text_sibling"     {"request":"<JSON text>","<field>":...}            *)
(*                                                                         *)
(* No tool takes a value nested past a few levels, so the call a nested    *)
(* text names is never one a tool runs: fx reads text at the limit and     *)
(* the tool refuses it, and deeper text is left as sent without reaching   *)
(* the encoder.                                                            *)
(*                                                                         *)
(* A call is sent, then run or refused by its tool, then replayed in the   *)
(* next request either flat or as sent. For shell and subagent the         *)
(* replayed form is the form the call was admitted and saved with.         *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(*   "today"          fx before JSON text was read: only an object       *)
(*                    wrapper is read                                      *)
(*   "no_bound"       text longer than the bound is read                  *)
(*   "siblings"       the text form is unwrapped with its siblings dropped*)
(*   "replay_raw"     read_tool_result reads the text but replays it as   *)
(*                    sent                                                 *)
(*   "decode_side"    shell's decoder reads the text instead of intake,   *)
(*                    so the call runs but is admitted and saved wrapped   *)
(*   "no_depth_bound" text nested past MaxDepth is read, and reaches the  *)
(*                    encoder                                              *)
(*   "action_list"    subagent intake unwraps only some of the tool's     *)
(*                    actions (an earlier list held message and run, which *)
(*                    is not an action)                                    *)
(*   "limit_exclusive" text nested exactly MaxDepth levels is refused     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Bug

\* json_depth.max_depth: the deepest nesting fx reads in JSON it does not write.
MaxDepth == 64

Tools == {"shell", "read_tool_result", "subagent"}
\* subagent_model_contract.Action
SubagentActions == {"message", "wait", "status", "stop", "close"}
Exact == {"flat", "object", "text"}
BadText == {"text_oversized", "text_not_object", "text_deep"}
Siblings == {"object_sibling", "text_sibling"}
Shapes == Exact \cup BadText \cup Siblings \cup {"text_nested"}
Phases == {"sent", "answered", "done"}
Forms == {"none", "flat", "as_sent"}

\* The action of a subagent call. The other tools have none.
ActionsOf(t) == IF t = "subagent" THEN SubagentActions ELSE {"none"}

\* How deep the text of a call nests. A call within the limit is a valid
\* one, which nests a level or two. 256 and 257 straddle the depth where
\* the encoder aborts.
DepthsOf(s) ==
    CASE s = "text_nested" -> {MaxDepth}
      [] s = "text_deep" -> {MaxDepth + 1, 256, 257, 300}
      [] OTHER -> {1}

VARIABLES
    tool,     \* the tool the call names
    action,   \* the subagent action the call asks for, or "none"
    shape,    \* how the model shaped its arguments
    depth,    \* how deep the text of the call nests
    phase,    \* "sent", "answered" once the tool ran or refused, "done" once replayed
    ran,      \* the tool ran the call
    replay,   \* how the next request replays the call
    encoded   \* the depth of the last value given to the JSON encoder, 0 for none

vars == <<tool, action, shape, depth, phase, ran, replay, encoded>>

\* requestWrapperObject: whether the text of `request` reads as an object.
TextReads(s) ==
    CASE s \in {"text", "text_sibling"} -> TRUE
      [] s = "text_nested" -> Bug # "limit_exclusive"
      [] s = "text_deep" -> Bug = "no_depth_bound"
      [] s = "text_oversized" -> Bug = "no_bound"
      [] OTHER -> FALSE

\* requestWrapperObject: whether the value of `request` reads as an object.
WrapperReads(s) ==
    \/ s \in {"object", "object_sibling"}
    \/ Bug # "today" /\ TextReads(s)

\* `request` is the call's one member. The siblings defect drops that rule
\* for the text form.
OneMember(s) ==
    \/ s \in {"object", "text", "text_nested", "text_deep", "text_oversized", "text_not_object"}
    \/ Bug = "siblings" /\ s = "text_sibling"

\* Whether the call names a call a tool can run: not text that is no object,
\* and not a value nested past what any tool takes.
ValidCall(s) == s \notin {"text_not_object", "text_nested", "text_deep"}

\* Whether subagent intake unwraps this action.
Listed(a) == Bug # "action_list" \/ a = "message"

\* Shell and subagent: the call is admitted and saved flat.
IntakeFlat(t, a, s) ==
    \/ s = "flat"
    \/ /\ t \in {"shell", "subagent"}
       /\ OneMember(s)
       /\ WrapperReads(s)
       /\ t = "subagent" => Listed(a)
       /\ ~(Bug = "decode_side" /\ t = "shell" /\ s = "text")

\* Whether the tool runs the call it was given. The subagent decoder reads
\* an object wrapper itself, and never its text.
Runs(t, a, s) ==
    /\ ValidCall(s)
    /\ IF t = "read_tool_result"
       THEN s = "flat" \/ WrapperReads(s)
       ELSE \/ IntakeFlat(t, a, s)
            \/ Bug = "decode_side" /\ t = "shell" /\ s = "text"
            \/ t = "subagent" /\ s = "object"

\* Whether the next request replays the call flat.
ReplaysFlat(t, a, s) ==
    IF t = "read_tool_result"
    THEN \/ s = "flat"
         \/ OneMember(s) /\ WrapperReads(s) /\ ~(Bug = "replay_raw" /\ s = "text")
    ELSE IntakeFlat(t, a, s)

\* The depth of what intake writes back out when it unwraps a call.
IntakeEncodes(t, a, s, d) ==
    IF t \in {"shell", "subagent"} /\ s # "flat" /\ IntakeFlat(t, a, s) THEN d ELSE 0

\* The depth of what the replay writes out when it unwraps a call.
ReplayEncodes(t, a, s, d) ==
    IF t = "read_tool_result" /\ s # "flat" /\ ReplaysFlat(t, a, s) THEN d ELSE 0

InitWith(t, a, s, d) ==
    /\ tool = t
    /\ action = a
    /\ shape = s
    /\ depth = d
    /\ phase = "sent"
    /\ ran = FALSE
    /\ replay = "none"
    /\ encoded = 0

Init ==
    \E t \in Tools : \E a \in ActionsOf(t) : \E s \in Shapes : \E d \in DepthsOf(s) :
        InitWith(t, a, s, d)

\* The next call, for trace validation of several calls in a row.
ResetTo(t, a, s, d) ==
    /\ tool' = t
    /\ action' = a
    /\ shape' = s
    /\ depth' = d
    /\ phase' = "sent"
    /\ ran' = FALSE
    /\ replay' = "none"
    /\ encoded' = 0

Run ==
    /\ phase = "sent"
    /\ Runs(tool, action, shape)
    /\ phase' = "answered"
    /\ ran' = TRUE
    /\ encoded' = IntakeEncodes(tool, action, shape, depth)
    /\ UNCHANGED <<tool, action, shape, depth, replay>>

Refuse ==
    /\ phase = "sent"
    /\ ~Runs(tool, action, shape)
    /\ phase' = "answered"
    /\ encoded' = IntakeEncodes(tool, action, shape, depth)
    /\ UNCHANGED <<tool, action, shape, depth, ran, replay>>

Replay ==
    /\ phase = "answered"
    /\ phase' = "done"
    /\ replay' = IF ReplaysFlat(tool, action, shape) THEN "flat" ELSE "as_sent"
    /\ encoded' = IF ReplayEncodes(tool, action, shape, depth) # 0
                  THEN depth ELSE encoded
    /\ UNCHANGED <<tool, action, shape, depth, ran>>

Finished == phase = "done" /\ UNCHANGED vars

Next == Run \/ Refuse \/ Replay \/ Finished

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ tool \in Tools
    /\ action \in SubagentActions \cup {"none"}
    /\ shape \in Shapes
    /\ depth \in Nat
    /\ phase \in Phases
    /\ ran \in BOOLEAN
    /\ replay \in Forms
    /\ encoded \in Nat

\* A flat call, an object wrapper, and the JSON text of one all run, for
\* every action a subagent call can ask for.
ExactWrapperRuns == phase \in {"answered", "done"} /\ shape \in Exact => ran

\* Text over the bound, text nested past the limit, or text that names no
\* object never runs.
BadTextRefused == phase = "done" /\ shape \in BadText => ~ran

\* A shell or subagent wrapper with fields beside it never runs with those
\* fields dropped; it reaches the tool as sent, whose error names the fix.
SiblingsNotDropped ==
    phase = "done" /\ tool \in {"shell", "subagent"} /\ shape \in Siblings => ~ran

\* Every exact wrapper that ran replays as the flat call the schema
\* advertises; for shell and subagent that is also the form review saw.
ReplayFlat == phase = "done" /\ ran /\ shape \in Exact => replay = "flat"

\* A call refused for its wrapper, over the bound, past the depth limit, or
\* beside fields replays the bytes the model sent. Text at the limit is read
\* and replays as the flat call its tool then refuses.
RefusedReplaysAsSent ==
    phase = "done" /\ ~ran /\ shape # "text_nested" => replay = "as_sent"

\* Text nested exactly MaxDepth levels is read.
DepthLimitInclusive == phase = "done" /\ shape = "text_nested" => replay = "flat"

\* fx never gives the JSON encoder a value nested past the limit.
EncoderDepthBounded == encoded <= MaxDepth
=============================================================================
