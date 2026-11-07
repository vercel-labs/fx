-------------------------- MODULE AcpChildApproval --------------------------
(***************************************************************************)
(* How a subagent's permission request reaches an ACP client through its   *)
(* parent session (src/acp/prompt.zig requestAcpPermission, the outbound   *)
(* registry in src/acp/server.zig, and the subagent turn in                *)
(* src/core/subagent/execution.zig requestChildPermission).                *)
(*                                                                         *)
(*  - A subagent that has no screen of its own asks through the prompter   *)
(*    its host handed it (Route = "host"). fx acp sends the request on the *)
(*    parent session and waits for its own answer; fx ask, which has no   *)
(*    prompter for subagents, denies at once (Route = "none"). Before the  *)
(*    change the subagent waited on its own worker, which nothing in ACP   *)
(*    reads (Route = "worker").                                            *)
(*  - A subagent request is admitted only while the parent's prompt is     *)
(*    open. The check and the insert are one step under outbound_mutex     *)
(*    (AtomicGate). Closing the prompt, by its end or by session/cancel,   *)
(*    shuts the gate and cancels every open subagent request in the same   *)
(*    step, which sends $/cancel_request: libfx drops a request that       *)
(*    arrives with no current turn (sdk/engine.js), so none may be left.   *)
(*  - A parent's stop, or the host shutting down, ends a subagent's wait   *)
(*    and cancels its request (StopCancelsWait).                           *)
(*  - The client answers allow, reject, garbage, or a JSON-RPC error. An   *)
(*    answer travels on the wire and can arrive after its request was      *)
(*    cancelled, and a client may answer a request fx already withdrew;   *)
(*    such an answer is dropped. Only allow runs the action (SEC-81).      *)
(*                                                                         *)
(* Each subagent reaches at most one gated action. The prompt can open     *)
(* again (a later session/prompt) while subagents of an earlier one still  *)
(* run, up to MaxPrompts times.                                            *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Children,        \* the subagents
          Route,           \* "host" (the design), "worker" (before), "none" (fx ask)
          AtomicGate,      \* TRUE: check the gate and insert in one step
          StopCancelsWait, \* TRUE: a stop ends a wait on the client
          MaxPrompts       \* how many prompts the session opens

ASSUME Route \in {"host", "worker", "none"}
ASSUME AtomicGate \in BOOLEAN /\ StopCancelsWait \in BOOLEAN
ASSUME MaxPrompts \in Nat \ {0}

Answers == {"allow", "reject", "garbage", "error"}
Settled == Answers \cup {"cancelled"}

VARIABLES
    prompt,    \* "open" | "closed": the parent's session/prompt
    prompts,   \* how many prompts have opened
    child,     \* "working" | "asking" | "waiting" | "done"
    sawOpen,   \* the split gate's remembered check (AtomicGate = FALSE only)
    entry,     \* the subagent's outbound entry: "none" | "open" | an answer | "cancelled"
    atClient,  \* the request is shown at the client, unanswered and not withdrawn
    wire,      \* an answer the client sent that fx has not read: "none" or an answer
    sent,      \* history: the request was sent to the client
    stopped,   \* the parent stopped the subagent, or its host shut down
    result,    \* "none" | "ran" | "denied"
    allowed    \* history: an allow reached this subagent's open entry

vars == <<prompt, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed>>

TypeOK ==
    /\ prompt \in {"open", "closed"}
    /\ prompts \in 1..MaxPrompts
    /\ child \in [Children -> {"working", "asking", "waiting", "done"}]
    /\ sawOpen \in [Children -> BOOLEAN]
    /\ entry \in [Children -> {"none", "open"} \cup Settled]
    /\ atClient \in [Children -> BOOLEAN]
    /\ wire \in [Children -> {"none"} \cup Answers]
    /\ sent \in [Children -> BOOLEAN]
    /\ stopped \in [Children -> BOOLEAN]
    /\ result \in [Children -> {"none", "ran", "denied"}]
    /\ allowed \in [Children -> BOOLEAN]

Init ==
    /\ prompt = "open"
    /\ prompts = 1
    /\ child = [c \in Children |-> "working"]
    /\ sawOpen = [c \in Children |-> FALSE]
    /\ entry = [c \in Children |-> "none"]
    /\ atClient = [c \in Children |-> FALSE]
    /\ wire = [c \in Children |-> "none"]
    /\ sent = [c \in Children |-> FALSE]
    /\ stopped = [c \in Children |-> FALSE]
    /\ result = [c \in Children |-> "none"]
    /\ allowed = [c \in Children |-> FALSE]

Deny(c) == /\ child' = [child EXCEPT ![c] = "done"]
           /\ result' = [result EXCEPT ![c] = "denied"]

----------------------------------------------------------------------------
(* The subagent's own turn.                                                *)

\* It reaches an action that needs approval.
Ask(c) ==
    /\ child[c] = "working"
    /\ ~stopped[c]
    /\ child' = [child EXCEPT ![c] = "asking"]
    /\ UNCHANGED <<prompt, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed>>

\* It ends without one, or a stop ends it first.
Finish(c) ==
    /\ child[c] = "working"
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ UNCHANGED <<prompt, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed>>

\* The design: the gated begin. Open prompt and a subagent not stopped:
\* insert, send, wait. Otherwise deny at once. A stop that lands after the
\* subagent read its stop flag is a Stop after this step.
Begin(c) ==
    /\ Route = "host" /\ AtomicGate
    /\ child[c] = "asking"
    /\ IF prompt = "open" /\ ~stopped[c]
         THEN /\ entry' = [entry EXCEPT ![c] = "open"]
              /\ atClient' = [atClient EXCEPT ![c] = TRUE]
              /\ sent' = [sent EXCEPT ![c] = TRUE]
              /\ child' = [child EXCEPT ![c] = "waiting"]
              /\ UNCHANGED result
         ELSE /\ Deny(c)
              /\ UNCHANGED <<entry, atClient, sent>>
    /\ UNCHANGED <<prompt, prompts, sawOpen, wire, stopped, allowed>>

\* A planted bug: the gate is read in one step ...
CheckGate(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ ~sawOpen[c]
    /\ IF prompt = "open" /\ ~stopped[c]
         THEN /\ sawOpen' = [sawOpen EXCEPT ![c] = TRUE]
              /\ UNCHANGED <<child, result>>
         ELSE /\ Deny(c)
              /\ UNCHANGED sawOpen
    /\ UNCHANGED <<prompt, prompts, entry, atClient, wire, sent, stopped, allowed>>

\* ... and the request inserted and sent in a later one.
InsertChecked(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ sawOpen[c]
    /\ sawOpen' = [sawOpen EXCEPT ![c] = FALSE]
    /\ entry' = [entry EXCEPT ![c] = "open"]
    /\ atClient' = [atClient EXCEPT ![c] = TRUE]
    /\ sent' = [sent EXCEPT ![c] = TRUE]
    /\ child' = [child EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<prompt, prompts, wire, stopped, result, allowed>>

\* Before the change: the subagent waits on its own worker, which nothing
\* in ACP reads.
WaitOnWorker(c) ==
    /\ Route = "worker"
    /\ child[c] = "asking"
    /\ child' = [child EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<prompt, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed>>

\* fx ask: no prompter for subagents, so deny at once.
NoHost(c) ==
    /\ Route = "none"
    /\ child[c] = "asking"
    /\ Deny(c)
    /\ UNCHANGED <<prompt, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed>>

\* The waiting subagent reads its settled entry and removes it.
Decide(c) ==
    /\ child[c] = "waiting"
    /\ entry[c] \in Settled
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ result' = [result EXCEPT ![c] = IF entry[c] = "allow" THEN "ran" ELSE "denied"]
    /\ entry' = [entry EXCEPT ![c] = "none"]
    /\ UNCHANGED <<prompt, prompts, sawOpen, atClient, wire, sent, stopped, allowed>>

----------------------------------------------------------------------------
(* The client and the reader thread.                                       *)

\* The client answers a request it shows. The answer is on the wire.
ClientSend(c, a) ==
    /\ atClient[c]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, prompts, child, sawOpen, entry, sent, stopped, result, allowed>>

\* A client that ignores $/cancel_request answers a request fx withdrew.
LateSend(c, a) ==
    /\ sent[c] /\ ~atClient[c] /\ wire[c] = "none"
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, prompts, child, sawOpen, entry, atClient, sent, stopped, result, allowed>>

\* handleClientResponse: an answer settles an open entry; an answer whose
\* entry is gone or already settled is dropped.
Deliver(c) ==
    /\ wire[c] # "none"
    /\ wire' = [wire EXCEPT ![c] = "none"]
    /\ IF entry[c] = "open"
         THEN /\ entry' = [entry EXCEPT ![c] = wire[c]]
              /\ allowed' = [allowed EXCEPT ![c] = allowed[c] \/ wire[c] = "allow"]
         ELSE UNCHANGED <<entry, allowed>>
    /\ UNCHANGED <<prompt, prompts, child, sawOpen, atClient, sent, stopped, result>>

----------------------------------------------------------------------------
(* The parent's prompt, the user, and the parent's stop.                  *)

\* Shut the gate: cancel every open subagent entry and withdraw its request.
CloseGate ==
    /\ entry' = [c \in Children |-> IF entry[c] = "open" THEN "cancelled" ELSE entry[c]]
    /\ atClient' = [c \in Children |-> FALSE]

\* The prompt ends once no subagent is working or waiting.
PromptEnd ==
    /\ prompt = "open"
    /\ \A c \in Children : child[c] = "done"
    /\ prompt' = "closed"
    /\ CloseGate
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed>>

\* session/cancel: the prompt ends now, with subagents still running.
Cancel ==
    /\ prompt = "open"
    /\ prompt' = "closed"
    /\ CloseGate
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed>>

\* A later session/prompt.
Reopen ==
    /\ prompt = "closed"
    /\ prompts < MaxPrompts
    /\ prompt' = "open"
    /\ prompts' = prompts + 1
    /\ UNCHANGED <<child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed>>

\* The parent stops a subagent, or its host shuts down.
Stop(c) ==
    /\ ~stopped[c]
    /\ child[c] # "done"
    /\ stopped' = [stopped EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<prompt, prompts, child, sawOpen, entry, atClient, wire, sent, result, allowed>>

\* The wait on the client polls the subagent's cancel flag.
StopWait(c) ==
    /\ Route = "host" /\ StopCancelsWait
    /\ stopped[c] /\ child[c] = "waiting" /\ entry[c] = "open"
    /\ entry' = [entry EXCEPT ![c] = "cancelled"]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<prompt, prompts, child, sawOpen, wire, sent, stopped, result, allowed>>

\* Before the change a stop reached the worker's wait (cancelApprovalTurn).
WorkerStop(c) ==
    /\ Route = "worker"
    /\ stopped[c] /\ child[c] = "waiting"
    /\ Deny(c)
    /\ UNCHANGED <<prompt, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed>>

----------------------------------------------------------------------------

FxStep(c) ==
    \/ Ask(c) \/ Finish(c) \/ Begin(c) \/ CheckGate(c) \/ InsertChecked(c)
    \/ WaitOnWorker(c) \/ NoHost(c) \/ Decide(c) \/ Deliver(c)
    \/ StopWait(c) \/ WorkerStop(c)

Next ==
    \/ \E c \in Children : FxStep(c)
    \/ \E c \in Children, a \in Answers : ClientSend(c, a) \/ LateSend(c, a)
    \/ \E c \in Children : Stop(c)
    \/ PromptEnd \/ Cancel \/ Reopen

\* fx's own steps are fair; the user, the parent's stop, and the client are
\* not, so a client may never answer.
FxFair ==
    /\ \A c \in Children :
        /\ WF_vars(Ask(c) \/ Finish(c))
        /\ WF_vars(Begin(c)) /\ WF_vars(CheckGate(c)) /\ WF_vars(InsertChecked(c))
        /\ WF_vars(WaitOnWorker(c)) /\ WF_vars(NoHost(c))
        /\ WF_vars(Decide(c)) /\ WF_vars(Deliver(c))
        /\ WF_vars(StopWait(c)) /\ WF_vars(WorkerStop(c))
    /\ WF_vars(PromptEnd)

Spec == Init /\ [][Next]_vars /\ FxFair

\* A client that answers every request it shows.
SpecAnswered == Spec /\ \A c \in Children : WF_vars(\E a \in Answers : ClientSend(c, a))

----------------------------------------------------------------------------
(* What must hold.                                                         *)

\* An action runs only after an allow for its own open request (SEC-81).
NoRunWithoutAllow == \A c \in Children : result[c] = "ran" => allowed[c]

\* No subagent request is shown at the client while no prompt is open.
NoStrandedRequest == prompt = "closed" => \A c \in Children : ~atClient[c]

\* Once the prompt closes, every subagent's wait ends, answered or not.
CloseEndsWait ==
    \A c \in Children : (prompt = "closed" /\ child[c] = "waiting") ~> (child[c] # "waiting")

\* A stop ends a subagent's wait, answered or not.
StopEndsWait ==
    \A c \in Children : (stopped[c] /\ child[c] = "waiting") ~> (child[c] # "waiting")

\* With a client that answers what it is sent, every prompt ends.
PromptEnds == (prompt = "open") ~> (prompt = "closed")
=============================================================================
