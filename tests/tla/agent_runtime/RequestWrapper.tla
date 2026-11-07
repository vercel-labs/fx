--------------------------- MODULE RequestWrapper ---------------------------
(***************************************************************************)
(* What fx does with one tool call whose arguments a model wrapped in a    *)
(* `request` member, for shell, read_tool_result, and subagent. All three  *)
(* are advertised with top-level arguments, and models still send the old  *)
(* wrapper, some of them, such as MiMo, as the JSON text of the object.    *)
(*                                                                         *)
(* fx reads a wrapper's value with tool_args.requestWrapperObject          *)
(* (src/core/tooling/tool_args.zig): the object itself, or the object its  *)
(* JSON text names when the text is at most max_request_text_bytes long.   *)
(* Shell and subagent calls are unwrapped when they arrive, only when      *)
(* `request` is the call's one member (normalized_terminal_request_        *)
(* arguments and normalized_subagent_request_arguments in                  *)
(* src/core/agent/runtime/orchestrator.zig), so admission, permission      *)
(* review, and the saved call all see the flat call, and a wrapper with    *)
(* fields beside it reaches the tool as sent. read_tool_result's decoder   *)
(* reads `request` whenever it is present (src/tools/session/              *)
(* read_tool_result.zig), and its history replay unwraps only an exact     *)
(* wrapper (projected_read_tool_result_arguments).                         *)
(*                                                                         *)
(* A call's shape is one of:                                               *)
(*   "flat"             top-level arguments, no wrapper                    *)
(*   "object"           {"request":{...}}                                  *)
(*   "text"             {"request":"<JSON text of an object>"}             *)
(*   "text_oversized"   the same, with text longer than the bound          *)
(*   "text_not_object"  {"request":"<text that is not an object>"}         *)
(*   "object_sibling"   {"request":{...},"<field>":...}                    *)
(*   "text_sibling"     {"request":"<JSON text>","<field>":...}            *)
(*                                                                         *)
(* A call is sent, then run or refused by its tool, then replayed in the   *)
(* next request either flat or as sent. For shell and subagent the         *)
(* replayed form is the form the call was admitted and saved with.         *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(*   "today"        fx before the change: only an object wrapper is read   *)
(*   "no_bound"     text longer than the bound is read                     *)
(*   "siblings"     the text form is unwrapped with its siblings dropped   *)
(*   "replay_raw"   read_tool_result reads the text but replays it as sent *)
(*   "decode_side"  shell's decoder reads the text instead of intake, so   *)
(*                  the call runs but is admitted and saved wrapped        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Bug

Tools == {"shell", "read_tool_result", "subagent"}
Exact == {"flat", "object", "text"}
BadText == {"text_oversized", "text_not_object"}
Siblings == {"object_sibling", "text_sibling"}
Shapes == Exact \cup BadText \cup Siblings
Phases == {"sent", "answered", "done"}
Forms == {"none", "flat", "as_sent"}

VARIABLES
    tool,    \* the tool the call names
    shape,   \* how the model shaped its arguments
    phase,   \* "sent", "answered" once the tool ran or refused, "done" once replayed
    ran,     \* the tool ran the call
    replay   \* how the next request replays the call

vars == <<tool, shape, phase, ran, replay>>

\* requestWrapperObject: whether the value of `request` reads as an object.
WrapperReads(s) ==
    CASE s \in {"object", "object_sibling"} -> TRUE
      [] s \in {"text", "text_sibling"} -> Bug # "today"
      [] s = "text_oversized" -> Bug = "no_bound"
      [] OTHER -> FALSE

\* `request` is the call's one member. The siblings defect drops that rule
\* for the text form.
OneMember(s) ==
    \/ s \in {"object", "text", "text_oversized", "text_not_object"}
    \/ Bug = "siblings" /\ s = "text_sibling"

\* Shell and subagent: the call is admitted and saved flat.
IntakeFlat(t, s) ==
    \/ s = "flat"
    \/ /\ t \in {"shell", "subagent"}
       /\ OneMember(s)
       /\ WrapperReads(s)
       /\ ~(Bug = "decode_side" /\ t = "shell" /\ s = "text")

\* Whether the tool runs the call it was given.
Runs(t, s) ==
    IF t = "read_tool_result"
    THEN s = "flat" \/ WrapperReads(s)
    ELSE IntakeFlat(t, s) \/ (Bug = "decode_side" /\ t = "shell" /\ s = "text")

\* Whether the next request replays the call flat.
ReplaysFlat(t, s) ==
    IF t = "read_tool_result"
    THEN \/ s = "flat"
         \/ OneMember(s) /\ WrapperReads(s) /\ ~(Bug = "replay_raw" /\ s = "text")
    ELSE IntakeFlat(t, s)

InitWith(t, s) ==
    /\ tool = t
    /\ shape = s
    /\ phase = "sent"
    /\ ran = FALSE
    /\ replay = "none"

Init == \E t \in Tools, s \in Shapes : InitWith(t, s)

\* The next call, for trace validation of several calls in a row.
ResetTo(t, s) ==
    /\ tool' = t
    /\ shape' = s
    /\ phase' = "sent"
    /\ ran' = FALSE
    /\ replay' = "none"

Run ==
    /\ phase = "sent"
    /\ Runs(tool, shape)
    /\ phase' = "answered"
    /\ ran' = TRUE
    /\ UNCHANGED <<tool, shape, replay>>

Refuse ==
    /\ phase = "sent"
    /\ ~Runs(tool, shape)
    /\ phase' = "answered"
    /\ UNCHANGED <<tool, shape, ran, replay>>

Replay ==
    /\ phase = "answered"
    /\ phase' = "done"
    /\ replay' = IF ReplaysFlat(tool, shape) THEN "flat" ELSE "as_sent"
    /\ UNCHANGED <<tool, shape, ran>>

Finished == phase = "done" /\ UNCHANGED vars

Next == Run \/ Refuse \/ Replay \/ Finished

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ tool \in Tools
    /\ shape \in Shapes
    /\ phase \in Phases
    /\ ran \in BOOLEAN
    /\ replay \in Forms

\* A flat call, an object wrapper, and the JSON text of one all run.
ExactWrapperRuns == phase = "done" /\ shape \in Exact => ran

\* Text over the bound, or text that names no object, never runs.
BadTextRefused == phase = "done" /\ shape \in BadText => ~ran

\* A shell or subagent wrapper with fields beside it never runs with those
\* fields dropped; it reaches the tool as sent, whose error names the fix.
SiblingsNotDropped ==
    phase = "done" /\ tool \in {"shell", "subagent"} /\ shape \in Siblings => ~ran

\* Every exact wrapper that ran replays as the flat call the schema
\* advertises; for shell and subagent that is also the form review saw.
ReplayFlat == phase = "done" /\ ran /\ shape \in Exact => replay = "flat"

\* A refused call replays the bytes the model sent.
RefusedReplaysAsSent == phase = "done" /\ ~ran => replay = "as_sent"
=============================================================================
