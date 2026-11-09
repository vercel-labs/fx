----------------------------- MODULE ToolArena -----------------------------
(***************************************************************************)
(* Where one fx turn keeps the memory of its tool calls: the per-call      *)
(* arena in src/core/agent/runtime/orchestrator.zig and the copy-out in    *)
(* executeRegisteredTool, src/core/tooling/tool_runtime.zig.               *)
(*                                                                         *)
(* A turn has one arena, freed when the turn ends. Each tool call is       *)
(* admitted, runs, and settles: its result joins the turn's history, which *)
(* every later request of the turn reads. What a call needs only while it  *)
(* runs, its scratch (decoding, permission context, the bytes a tool reads *)
(* before it formats its result), should go when the call ends. fx used to *)
(* give every call but a file mutation the turn's arena as its allocator,  *)
(* so each call's scratch stayed until the turn ended (#483).              *)
(*                                                                         *)
(* A call is one of:                                                       *)
(*   "dispatched"  a tool fx dispatches itself (read_file, grep_files, an  *)
(*                 MCP tool, a subagent): it runs on the call's arena, and *)
(*                 only its result is copied to the turn                   *)
(*   "backend"     shell or vision: the backend builds the completion the  *)
(*                 turn adopts, its command replay capture included, so it *)
(*                 runs on the turn's allocator                            *)
(*   "mutation"    write_file or edit_file, which already ran on a call    *)
(*                 arena and copied its result out                         *)
(*   "parallel"    one call of a read-only batch, run in its own slot      *)
(*                 arena and copied out (parallel_execution.zig)           *)
(*   "prelude"     a call fx answers before dispatch, such as an unknown   *)
(*                 tool                                                    *)
(* and ends one of:                                                        *)
(*   "success", "failure"  the tool returned a result                      *)
(*   "error"      the tool returned an error, which fx formats             *)
(*   "denied"     permission refused it, so it never ran                   *)
(*   "cancelled"  the user cancelled it, which ends the turn               *)
(*   "finish"     an MCP call that ends the turn with McpInputRequired     *)
(* large is whether the call read a large file, the part of its scratch    *)
(* the drivers can measure.                                                *)
(*                                                                         *)
(* A result is a set of fields, each in one place: "body" (model_output),  *)
(* "memory" (tool_result_memory: preview, handles, images), "json"         *)
(* (command_result_json), "subagent" (the subagent status strings), and    *)
(* "detail" (status_detail, which fx ask keeps after the turn as its error *)
(* code, src/core/cli/cli_ask.zig). A place is "turn", "call" (the current *)
(* call's own arena), "static", "none", or "freed" once its arena is gone. *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch it.      *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxCalls, Bug

Kinds == {"dispatched", "backend", "mutation", "parallel", "prelude"}
Outcomes == {"success", "failure", "error", "denied", "cancelled", "finish"}
Fields == {"body", "memory", "json", "subagent", "detail"}
Places == {"none", "turn", "call", "static", "freed"}
Phases == {"idle", "admitted", "ran", "copied", "settled", "ending", "ended"}
Bugs == {"none", "today", "shallow_copy", "dupe_error_code",
         "backend_call_arena", "error_on_call_arena", "free_before_copy",
         "leak_on_return"}

OutcomesFor(k) ==
    CASE k = "dispatched" -> Outcomes
      [] k = "backend"    -> {"success", "failure", "error", "denied", "cancelled"}
      [] k = "mutation"   -> {"success", "failure", "denied", "cancelled"}
      [] k = "parallel"   -> {"success", "failure", "error"}
      [] k = "prelude"    -> {"failure"}

Nothing == [f \in Fields |-> "none"]

VARIABLES
    phase,         \* where the turn is
    n,             \* calls admitted so far
    kind,          \* the current call's kind
    outcome,       \* how the current call ends
    large,         \* the current call read a large file
    arena,         \* the current call's own arena: "none", "live", "freed"
    result,        \* the current call's result: Fields -> Places
    history,       \* the results the turn keeps, in order
    turnScratch,   \* calls whose scratch the turn arena kept
    largeScratch,  \* of those, calls that read a large file
    backendScratch,\* backend calls, whose scratch the turn keeps by design
    errorCode,     \* where fx ask's error code lives after the turn
    readFreed      \* fx read a field after its arena was freed

vars == <<phase, n, kind, outcome, large, arena, result, history,
          turnScratch, largeScratch, backendScratch, errorCode, readFreed>>

Init ==
    /\ phase = "idle"
    /\ n = 0
    /\ kind = "prelude"
    /\ outcome = "failure"
    /\ large = FALSE
    /\ arena = "none"
    /\ result = Nothing
    /\ history = <<>>
    /\ turnScratch = 0
    /\ largeScratch = 0
    /\ backendScratch = 0
    /\ errorCode = "none"
    /\ readFreed = FALSE

\* A new turn, for ToolArenaTrace.tla, which replays several.
Reset ==
    /\ phase' = "idle"
    /\ n' = 0
    /\ kind' = "prelude"
    /\ outcome' = "failure"
    /\ large' = FALSE
    /\ arena' = "none"
    /\ result' = Nothing
    /\ history' = <<>>
    /\ turnScratch' = 0
    /\ largeScratch' = 0
    /\ backendScratch' = 0
    /\ errorCode' = "none"
    /\ readFreed' = FALSE

\* Which calls get their own arena. A parallel slot always had one.
OwnArena(k) ==
    \/ k \in {"mutation", "parallel"}
    \/ (k \in {"dispatched", "backend"} /\ Bug # "today")

\* The allocator a call's tool runs on.
DispatchPlace(k) ==
    CASE k = "backend"    -> IF Bug = "backend_call_arena" THEN "call" ELSE "turn"
      [] k = "dispatched" -> IF Bug = "today" THEN "turn" ELSE "call"
      [] k \in {"mutation", "parallel"} -> "call"
      [] k = "prelude"    -> "turn"

\* Free the current call's arena: whatever still points into it is gone.
Gone(p) == IF p = "call" THEN "freed" ELSE p
FreeArena ==
    /\ arena' = IF arena = "live" THEN "freed" ELSE arena
    /\ result' = [f \in Fields |-> Gone(result[f])]
    /\ history' = [i \in DOMAIN history |-> [f \in Fields |-> Gone(history[i][f])]]

AdmitCall(k, o, l) ==
    /\ phase = "idle"
    /\ n < MaxCalls
    /\ k \in Kinds
    /\ o \in OutcomesFor(k)
    /\ phase' = "admitted"
    /\ n' = n + 1
    /\ kind' = k
    /\ outcome' = o
    /\ large' = l
    /\ arena' = IF OwnArena(k) THEN "live" ELSE "none"
    /\ result' = Nothing
    /\ UNCHANGED <<history, turnScratch, largeScratch, backendScratch, errorCode, readFreed>>

Admit == \E k \in Kinds, o \in Outcomes, l \in BOOLEAN : AdmitCall(k, o, l)

\* The call runs, or is refused, and its result takes shape where its tool
\* allocates. A refused call's denial text is built on the turn's arena.
Run ==
    /\ phase = "admitted"
    /\ LET d == DispatchPlace(kind)
           runs == outcome # "denied"
           inTurn == runs /\ kind # "prelude" /\ d = "turn"
       IN
       /\ result' =
            CASE outcome = "denied" -> [Nothing EXCEPT !["body"] = "turn"]
              [] outcome = "error" ->
                   [Nothing EXCEPT !["body"] =
                       IF Bug = "error_on_call_arena" THEN "call" ELSE "turn"]
              [] OTHER ->
                   [f \in Fields |->
                       IF f = "detail"
                       THEN IF outcome = "finish" THEN "static" ELSE "none"
                       ELSE d]
       /\ turnScratch' = turnScratch + (IF inTurn /\ kind # "backend" THEN 1 ELSE 0)
       /\ largeScratch' = largeScratch + (IF inTurn /\ kind # "backend" /\ large THEN 1 ELSE 0)
       /\ backendScratch' = backendScratch + (IF inTurn /\ kind = "backend" THEN 1 ELSE 0)
    /\ phase' = "ran"
    /\ UNCHANGED <<n, kind, outcome, large, arena, history, errorCode, readFreed>>

\* At the executeRegisteredTool boundary, and in duplicateParallelToolResult
\* and the file mutation path, what lives on the call's arena moves to the
\* turn. status_detail is never copied: a dispatched call sets it only to
\* the static McpInputRequired.
Moved(f, p) ==
    IF p = "call"
    THEN IF Bug = "shallow_copy" /\ f = "memory" THEN "call" ELSE "turn"
    ELSE IF f = "detail" /\ p = "static" /\ Bug = "dupe_error_code" THEN "turn"
    ELSE p
\* A call that returned an error, or never ran, has no result to copy: the
\* step loop builds its text itself.
CopiesOut ==
    /\ kind \in {"dispatched", "mutation", "parallel"}
    /\ arena = "live"
    /\ outcome \notin {"error", "denied"}
CopyOut ==
    /\ phase = "ran"
    /\ IF CopiesOut /\ Bug = "free_before_copy"
       THEN /\ arena' = "freed"
            /\ readFreed' = (readFreed \/ \E f \in Fields : result[f] = "call")
            /\ result' = [f \in Fields |-> IF result[f] = "call" THEN "turn" ELSE result[f]]
       ELSE /\ result' = IF CopiesOut
                         THEN [f \in Fields |-> Moved(f, result[f])]
                         ELSE result
            /\ UNCHANGED <<arena, readFreed>>
    /\ phase' = "copied"
    /\ UNCHANGED <<n, kind, outcome, large, history, turnScratch, largeScratch,
                   backendScratch, errorCode>>

\* The step loop reads the result, adds it to the turn's history, and for a
\* turn-ending MCP call keeps its error code for fx ask.
Settle ==
    /\ phase = "copied"
    /\ readFreed' = (readFreed \/ \E f \in Fields : result[f] = "freed")
    /\ history' = Append(history, result)
    /\ errorCode' = IF outcome = "finish" THEN result["detail"] ELSE errorCode
    /\ phase' = "settled"
    /\ UNCHANGED <<n, kind, outcome, large, arena, result, turnScratch,
                   largeScratch, backendScratch>>

\* The loop iteration ends, on every path out of it, and frees the call's
\* arena. A cancelled call or one that ends the turn returns from the loop.
Free ==
    /\ phase = "settled"
    /\ IF Bug = "leak_on_return" /\ outcome \in {"cancelled", "finish"}
       THEN UNCHANGED <<arena, result, history>>
       ELSE FreeArena
    /\ phase' = IF outcome \in {"cancelled", "finish"} THEN "ending" ELSE "idle"
    /\ UNCHANGED <<n, kind, outcome, large, turnScratch, largeScratch,
                   backendScratch, errorCode, readFreed>>

\* The turn ends and its arena goes. fx ask still prints the error code.
EndTurn ==
    /\ phase \in {"idle", "ending"}
    /\ phase' = "ended"
    /\ errorCode' = IF errorCode = "turn" THEN "freed" ELSE errorCode
    /\ UNCHANGED <<n, kind, outcome, large, arena, result, history, turnScratch,
                   largeScratch, backendScratch, readFreed>>

Next == Admit \/ Run \/ CopyOut \/ Settle \/ Free \/ EndTurn

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in Phases
    /\ n \in 0..MaxCalls
    /\ kind \in Kinds
    /\ outcome \in Outcomes
    /\ large \in BOOLEAN
    /\ arena \in {"none", "live", "freed"}
    /\ result \in [Fields -> Places]
    /\ \A i \in DOMAIN history : history[i] \in [Fields -> Places]
    /\ turnScratch \in 0..MaxCalls
    /\ largeScratch \in 0..MaxCalls
    /\ backendScratch \in 0..MaxCalls
    /\ errorCode \in Places
    /\ readFreed \in BOOLEAN
    /\ Bug \in Bugs

\* The turn keeps no call's scratch, only backends', which by design build
\* the completion the turn adopts.
TurnKeepsOnlyResults == turnScratch = 0

\* Nothing the turn's history holds points into a freed call arena, so
\* every later request of the turn reads live memory.
NoDanglingHistory ==
    phase # "ended" =>
        \A i \in DOMAIN history : \A f \in Fields : history[i][f] # "freed"

\* fx never copies from, or reads, a call arena it already freed.
NoReadAfterFree == ~readFreed

\* The error code fx ask prints after the turn's arena is gone is static.
ErrorCodeOutlivesTurn == errorCode # "freed"

\* Every path out of a call frees its arena before the next call or the end
\* of the turn.
CallArenaFreed == phase \in {"idle", "ending", "ended"} => arena # "live"
=============================================================================
