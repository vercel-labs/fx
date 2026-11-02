--------------------------- MODULE ShellContract ---------------------------
(***************************************************************************)
(* One model turn of fx's shell tool pipeline (src/tools/shell/shell.zig    *)
(* decode, src/core/agent/runtime/orchestrator.zig processQueuedPromptLoop):*)
(*                                                                         *)
(*   model emits a call -> gateway passes the bytes unchanged              *)
(*     -> orchestrator normalizes (unwraps an exact {"request":{...}})     *)
(*     -> permission admission reads the arguments                         *)
(*     -> shell decode accepts or rejects                                  *)
(*     -> execute in a shell -> record the result                          *)
(*     -> history replay for the next model request                        *)
(*     -> loop guard ends the turn on a repeated invalid call.             *)
(*                                                                         *)
(* Design = "current" models the shell tool as fx implements it;          *)
(* Design = "proposed" models a redesign. AdmissionReads and              *)
(* GuessAmbiguous are mutation                                             *)
(* knobs that prove two of the invariants can fail.                        *)
(*                                                                         *)
(* Abstraction: a call is an (intent, shape) pair. The intent is what the  *)
(* model meant; the shape is how the arguments were encoded. Provider      *)
(* corruption and model quality are outside this model.                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

CONSTANTS
  Design,          \* "current" | "proposed"
  AdmissionReads,  \* "normalized" | "raw": what permission admission parses
  GuessAmbiguous,  \* TRUE makes the decoder guess on ambiguous calls (mutation)
  MaxCalls         \* bound on shell calls per turn

ASSUME Design \in {"current", "proposed"}
ASSUME AdmissionReads \in {"normalized", "raw"}
ASSUME GuessAmbiguous \in BOOLEAN
ASSUME MaxCalls \in Nat /\ MaxCalls >= 1

(* What the model meant.                                                    *)
(*   run          plain command in the default shell                        *)
(*   run_eq       command whose bash-style text zsh treats differently       *)
(*                (=word, an unmatched glob, ${arr[0]})                      *)
(*   run_bash     command in bash, no terminal                               *)
(*   run_bash_tty command in bash with a terminal                            *)
(*   type / observe / stop   act on an existing session                      *)
Intents == {"run", "run_eq", "run_bash", "run_bash_tty", "type", "observe", "stop"}

(* How the arguments arrived (all seen in real sessions or the evals).       *)
(*   flat_new        proposed flat form: command | session_id (+ input, stop)*)
(*   flat_action     flat with an action field, today's advertised form      *)
(*   wrapped         {"request": {...}}, the earlier advertised form         *)
(*   wrapped_string  {"request": "<valid JSON>"}  (Qwen, Nemotron)           *)
(*   wrapped_broken  {"request": "<invalid JSON>"} (GLM escaping)            *)
(*   invalid_json    the whole argument text is not JSON (long heredocs)     *)
(*   legacy_names    flat, no action, old names (tty, chars, yield_time_ms)  *)
(*   with_irrelevant flat plus a default-valued field that does not apply    *)
(*   both_input      command + session_id + input: means "type"              *)
(*   both_bare       command + session_id only: ambiguous                    *)
Shapes == {"flat_new", "flat_action", "wrapped", "wrapped_string", "wrapped_broken",
           "invalid_json", "legacy_names", "with_irrelevant", "both_input", "both_bare"}

Encodable(i, s) ==
  CASE s = "both_input" -> i = "type"
    [] s = "both_bare"  -> i = "observe"
    [] OTHER            -> TRUE

Emits == {e \in [intent : Intents, shape : Shapes] : Encodable(e.intent, e.shape)}
NoCall == [intent |-> "none", shape |-> "none"]

Unreadable == {"wrapped_broken", "invalid_json"}
Ambiguous  == {"both_bare"}

(* The intent can be read from the bytes exactly, without guessing.         *)
ExactlyReadable(e) == e.shape \notin (Unreadable \cup Ambiguous)

(* current: a call without action whose fields fit exactly one action gets *)
(*   that action before it is stored or admitted                             *)
(*   (normalize_terminal_request_tool_calls with shell's inferAction). Every *)
(*   legacy_names call fits one; the proposed flat form fits one only for a  *)
(*   plain command, whose field names are today's.                           *)
Inferred(e) ==
  /\ Design = "current"
  /\ \/ e.shape = "legacy_names"
     \/ e.shape = "flat_new" /\ e.intent \in {"run", "run_eq", "run_bash"}

CurrentReadable(e) == e.shape \in {"flat_action", "wrapped"} \/ Inferred(e)

(* Shell decode.                                                             *)
(* current: fx accepts the exact wrapper, flat-with-action, and an inferred *)
(*   call, and rejects an explicit shell without tty. Checked against the    *)
(*   fresh build.                                                            *)
(* proposed: forgiving decoder.                                             *)
Accepted(e) ==
  IF Design = "current"
  THEN CurrentReadable(e) /\ e.intent # "run_bash"
  ELSE \/ ExactlyReadable(e)
       \/ (GuessAmbiguous /\ e.shape \in Ambiguous)

(* A guessing decoder reads "both_bare" as a new command.                    *)
Decoded(e) == IF e.shape \in Ambiguous THEN "run" ELSE e.intent

(* What permission admission sees. Today the orchestrator unwraps the exact  *)
(* wrapper and adds an inferred action before admission, so admission and   *)
(* decode agree. The redesign needs one normalization step feeding both;    *)
(* AdmissionReads = "raw" models the bug where admission parses the         *)
(* original bytes instead.                                                   *)
RawReadable(e) == e.shape \in {"flat_action", "flat_new", "with_irrelevant"}
NormalizedView(e) ==
  IF Design = "current"
  THEN IF CurrentReadable(e) THEN e.intent ELSE "unreadable"
  ELSE IF Accepted(e) THEN Decoded(e) ELSE "unreadable"
AdmissionView(e) ==
  IF AdmissionReads = "normalized" THEN NormalizedView(e)
  ELSE IF RawReadable(e) THEN e.intent ELSE "unreadable"

(* How the call appears in the next request's history.                       *)
(* current: accepted calls are stored and replayed flat with their action; a  *)
(*   rejected call is replayed as stored, which is as sent except that the    *)
(*   orchestrator unwrapped an exact wrapper or added an inferred action      *)
(*   before the call was stored (normalize_terminal_request_tool_calls).      *)
(* proposed: accepted calls appear in canonical form; rejected calls appear   *)
(*   exactly as sent.                                                         *)
(* Argument text that is not JSON cannot be replayed: providers require JSON  *)
(* in history, so fx shows a {} placeholder in both designs.                 *)
HistoryEntry(e, acc) ==
  IF acc THEN "canonical"
  ELSE IF e.shape = "invalid_json" THEN "placeholder"
  ELSE IF Design = "current" /\ e.shape = "wrapped" THEN "unwrapped:wrapped"
  ELSE IF Inferred(e) THEN "inferred:" \o e.shape
  ELSE "as_sent:" \o e.shape

(* Result of bash-style text in the default shell (zsh). The redesign sets  *)
(* unsetopt equals, setopt nonomatch kshzerosubscript.                       *)
ZshOutcome == IF Design = "current" THEN "zsh_divergent" ELSE "bash_equivalent"

Outcome(e) ==
  IF ~Accepted(e) THEN "rejected"
  ELSE IF Decoded(e) = "run_eq" THEN ZshOutcome
  ELSE "ok"

(* What one call produces. ShellTrace and ShellOracle reuse this, so runtime *)
(* conformance is checked against the same definition the model uses.       *)
Record(e) ==
  [e        |-> e,
   accepted |-> Accepted(e),
   decoded  |-> IF Accepted(e) THEN Decoded(e) ELSE "none",
   checked  |-> AdmissionView(e),
   history  |-> HistoryEntry(e, Accepted(e)),
   outcome  |-> Outcome(e)]

VARIABLES phase, pending, calls, lastRejected
vars == <<phase, pending, calls, lastRejected>>

Init ==
  /\ phase = "model"
  /\ pending = NoCall
  /\ calls = << >>
  /\ lastRejected = NoCall

ModelEmit ==
  /\ phase = "model"
  /\ Len(calls) < MaxCalls
  /\ \E e \in Emits : pending' = e
  /\ phase' = "pipeline"
  /\ UNCHANGED <<calls, lastRejected>>

ModelFinish ==
  /\ phase = "model"
  /\ phase' = "done"
  /\ UNCHANGED <<pending, calls, lastRejected>>

Process ==
  /\ phase = "pipeline"
  /\ LET e   == pending
         acc == Accepted(e)
         repeatedInvalid == ~acc /\ e = lastRejected
     IN /\ calls' = Append(calls, Record(e))
        /\ lastRejected' = IF acc THEN NoCall ELSE e
        /\ pending' = NoCall
        /\ phase' = IF repeatedInvalid \/ Len(calls) + 1 = MaxCalls THEN "done" ELSE "model"

Finished == phase = "done" /\ UNCHANGED vars

Next == ModelEmit \/ ModelFinish \/ Process \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Process) /\ WF_vars(ModelFinish)

-----------------------------------------------------------------------------
(* Invariants.                                                              *)

TypeOK ==
  /\ phase \in {"model", "pipeline", "done"}
  /\ pending \in Emits \cup {NoCall}
  /\ lastRejected \in Emits \cup {NoCall}
  /\ Len(calls) <= MaxCalls

Calls == 1..Len(calls)

(* Never run a guessed intent.                                              *)
Exactness == \A k \in Calls : calls[k].accepted => calls[k].decoded = calls[k].e.intent

(* Permission checks exactly what will run.                                 *)
AdmissionConsistency == \A k \in Calls : calls[k].accepted => calls[k].checked = calls[k].decoded

(* Every call fx can read exactly is run.                                   *)
Completeness == \A k \in Calls : ExactlyReadable(calls[k].e) => calls[k].accepted

(* History shows rejected calls exactly as sent, except text that         *)
(* is not JSON, which can only be shown as a placeholder.                    *)
HistoryFidelity ==
  \A k \in Calls :
    IF calls[k].accepted THEN calls[k].history = "canonical"
    ELSE IF calls[k].e.shape = "invalid_json" THEN calls[k].history = "placeholder"
    ELSE calls[k].history = "as_sent:" \o calls[k].e.shape

(* Bash-style text in default zsh behaves like bash for the modeled       *)
(* constructs (=word, unmatched glob, ${arr[0]}).                            *)
ZshForgiving ==
  \A k \in Calls : (calls[k].accepted /\ calls[k].decoded = "run_eq") => calls[k].outcome = "bash_equivalent"

(* Loop guard: two identical rejected calls in a row end the turn.           *)
GuardBound ==
  \A k \in 1..(Len(calls) - 1) :
    (~calls[k].accepted /\ ~calls[k + 1].accepted /\ calls[k].e = calls[k + 1].e)
      => (k + 1 = Len(calls) /\ phase = "done")

(* Every processed call has exactly one recorded result.                     *)
OneResultPerCall == phase # "pipeline" => pending = NoCall

(* Liveness: every turn ends.                                                *)
Termination == <>(phase = "done")
=============================================================================
