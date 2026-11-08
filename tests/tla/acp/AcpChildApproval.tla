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
(*    prompter for subagents, refuses at once (Route = "none"). Before the *)
(*    change the subagent waited on its own worker, which nothing in ACP   *)
(*    reads (Route = "worker").                                            *)
(*  - A subagent request is admitted only while the parent's prompt is     *)
(*    open. The check and the insert are one step under outbound_mutex     *)
(*    (AtomicGate). Closing the prompt, by its end or by session/cancel,   *)
(*    shuts the gate and cancels every open subagent request in the same   *)
(*    step, which sends $/cancel_request: libfx drops a request that       *)
(*    arrives with no current turn (sdk/engine.js), so none may be left.   *)
(*    A prompt that fails to start must leave the gate shut                *)
(*    (SpawnClosesGate): its thread never runs to close it.                *)
(*  - The request has three steps: the insert, which also announces the    *)
(*    call's card as pending, then the write. A cancel can land between    *)
(*    them; the request is then written after its $/cancel_request went    *)
(*    out, so it is withdrawn again after the write (ResendCancel).        *)
(*  - The card ends once, with the call's real status (FinishCards): the   *)
(*    child's runtime reports the call's end, and the run's end settles    *)
(*    a card no call ended. A subagent's call ids carry its child id       *)
(*    (PrefixIds), since every conversation numbers its calls from one.    *)
(*  - The registry holds Capacity entries for every kind of request. A     *)
(*    subagent's requests count against one fewer (ReserveSlot), so the    *)
(*    parent's own request always finds a slot. Subagents past the two     *)
(*    modeled ones are `others`: anonymous requests that only take slots.  *)
(*  - A parent's stop, or the host shutting down, ends a subagent's wait   *)
(*    and cancels its request (StopCancelsWait).                           *)
(*  - The client answers allow, reject, garbage, or a JSON-RPC error. An   *)
(*    answer travels on the wire and can arrive after its request was      *)
(*    cancelled, and a client may answer a request fx already withdrew;   *)
(*    such an answer is dropped, and fx traces the drop. Only an allow     *)
(*    runs the action: a cancelled, error, malformed, or unknown answer    *)
(*    denies.                                                              *)
(*                                                                         *)
(* Each subagent reaches at most one gated action. The prompt can open     *)
(* again (a later session/prompt) while subagents of an earlier one still  *)
(* run, up to MaxPrompts times, and a start can fail.                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Children,        \* the subagents modeled one by one
          Route,           \* "host" (the design), "worker" (before), "none" (fx ask)
          AtomicGate,      \* TRUE: check the gate and insert in one step
          StopCancelsWait, \* TRUE: a stop ends a wait on the client
          MaxPrompts,      \* how many prompts the session starts
          FinishCards,     \* TRUE: a card ends once the call it shows has an outcome
          SpawnClosesGate, \* TRUE: a prompt that fails to start shuts the gate again
          PrefixIds,       \* TRUE: a subagent's call id carries its child id
          ReserveSlot,     \* TRUE: subagent requests leave the last slot to the parent
          ResendCancel,    \* TRUE: a request cancelled before its write is withdrawn again
          OthersMayAsk,    \* TRUE: subagents past the modeled ones may ask (off to check liveness)
          Capacity         \* entries the registry holds, for every kind of request

ASSUME Route \in {"host", "worker", "none"}
ASSUME AtomicGate \in BOOLEAN /\ StopCancelsWait \in BOOLEAN
ASSUME FinishCards \in BOOLEAN /\ SpawnClosesGate \in BOOLEAN /\ PrefixIds \in BOOLEAN
ASSUME ReserveSlot \in BOOLEAN /\ ResendCancel \in BOOLEAN /\ OthersMayAsk \in BOOLEAN
ASSUME MaxPrompts \in Nat \ {0}
ASSUME Capacity \in Nat \ {0}

Answers == {"allow", "reject", "garbage", "error"}
Settled == Answers \cup {"cancelled"}
FinalCards == {"completed", "failed"}

VARIABLES
    prompt,    \* "open" | "closed": the parent's session/prompt
    gate,      \* "open" | "closed": subagent_asks_open
    prompts,   \* how many prompts have started
    child,     \* "working" | "asking" | "sending" | "waiting" | "done"
    sawOpen,   \* the split gate's remembered check (AtomicGate = FALSE only)
    entry,     \* the subagent's outbound entry: "none" | "open" | an answer | "cancelled"
    atClient,  \* the request is shown at the client, unanswered and not withdrawn
    wire,      \* an answer the client sent that fx has not read: "none" or an answer
    sent,      \* history: the request was written to the client
    stopped,   \* the parent stopped the subagent, or its host shut down
    result,    \* "none" | "ran" | "denied"
    allowed,   \* history: an allow reached this subagent's open entry
    card,      \* the call's card: "none" | "pending" | "completed" | "failed"
    others,    \* open requests of subagents that are not modeled one by one
    parent     \* the parent's own request: "none" | "open" | "done" | "failed"

vars == <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

TypeOK ==
    /\ prompt \in {"open", "closed"}
    /\ gate \in {"open", "closed"}
    /\ prompts \in 1..MaxPrompts
    /\ child \in [Children -> {"working", "asking", "sending", "waiting", "done"}]
    /\ sawOpen \in [Children -> BOOLEAN]
    /\ entry \in [Children -> {"none", "open"} \cup Settled]
    /\ atClient \in [Children -> BOOLEAN]
    /\ wire \in [Children -> {"none"} \cup Answers]
    /\ sent \in [Children -> BOOLEAN]
    /\ stopped \in [Children -> BOOLEAN]
    /\ result \in [Children -> {"none", "ran", "denied"}]
    /\ allowed \in [Children -> BOOLEAN]
    /\ card \in [Children -> {"none", "pending"} \cup FinalCards]
    /\ others \in 0..Capacity
    /\ parent \in {"none", "open", "done", "failed"}

Init ==
    /\ prompt = "open"
    /\ gate = "open"
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
    /\ card = [c \in Children |-> "none"]
    /\ others = 0
    /\ parent = "none"

\* Slots in use: every subagent's entry, the anonymous ones, and the parent's.
Used ==
    Cardinality({c \in Children : entry[c] # "none"}) + others + (IF parent = "open" THEN 1 ELSE 0)

\* How many entries a subagent's request may find before it is refused.
ChildLimit == IF ReserveSlot THEN Capacity - 1 ELSE Capacity

Deny(c) == /\ child' = [child EXCEPT ![c] = "done"]
           /\ result' = [result EXCEPT ![c] = "denied"]

----------------------------------------------------------------------------
(* The subagent's own turn.                                                *)

\* It reaches an action that needs approval.
Ask(c) ==
    /\ child[c] = "working"
    /\ ~stopped[c]
    /\ child' = [child EXCEPT ![c] = "asking"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

\* It ends without one, or a stop ends it first.
Finish(c) ==
    /\ child[c] = "working"
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

\* The design: the gated insert. An open gate, a subagent not stopped, and a
\* free slot: insert the entry and announce the card. Otherwise refuse at once,
\* with no card. A stop that lands after the subagent read its stop flag is a
\* Stop after this step.
Begin(c) ==
    /\ Route = "host" /\ AtomicGate
    /\ child[c] = "asking"
    /\ IF gate = "open" /\ ~stopped[c] /\ Used < ChildLimit
         THEN /\ entry' = [entry EXCEPT ![c] = "open"]
              /\ card' = [card EXCEPT ![c] = "pending"]
              /\ child' = [child EXCEPT ![c] = "sending"]
              /\ UNCHANGED result
         ELSE /\ Deny(c)
              /\ UNCHANGED <<entry, card>>
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, atClient, wire, sent, stopped, allowed, others, parent>>

\* A planted bug: the gate is read in one step ...
CheckGate(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ ~sawOpen[c]
    /\ IF gate = "open" /\ ~stopped[c] /\ Used < ChildLimit
         THEN /\ sawOpen' = [sawOpen EXCEPT ![c] = TRUE]
              /\ UNCHANGED <<child, result>>
         ELSE /\ Deny(c)
              /\ UNCHANGED sawOpen
    /\ UNCHANGED <<prompt, gate, prompts, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>

\* ... and the request inserted in a later one.
InsertChecked(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ sawOpen[c]
    /\ sawOpen' = [sawOpen EXCEPT ![c] = FALSE]
    /\ entry' = [entry EXCEPT ![c] = "open"]
    /\ card' = [card EXCEPT ![c] = "pending"]
    /\ child' = [child EXCEPT ![c] = "sending"]
    /\ UNCHANGED <<prompt, gate, prompts, atClient, wire, sent, stopped, result, allowed, others, parent>>

\* The write. An entry cancelled since its insert had its $/cancel_request sent
\* ahead of the request. With ResendCancel the request is withdrawn again after
\* the write, so the client is left showing nothing; without it the client
\* shows a request that nobody waits for.
Send(c) ==
    /\ Route = "host"
    /\ child[c] = "sending"
    /\ sent' = [sent EXCEPT ![c] = TRUE]
    /\ atClient' = [atClient EXCEPT ![c] = entry[c] = "open" \/ ~ResendCancel]
    /\ child' = [child EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, wire, stopped, result, allowed, card, others, parent>>

\* Before the change: the subagent waits on its own worker, which nothing
\* in ACP reads.
WaitOnWorker(c) ==
    /\ Route = "worker"
    /\ child[c] = "asking"
    /\ child' = [child EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

\* fx ask: no prompter for subagents, so refuse at once.
NoHost(c) ==
    /\ Route = "none"
    /\ child[c] = "asking"
    /\ Deny(c)
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>

\* The waiting subagent reads its settled entry and removes it.
Decide(c) ==
    /\ child[c] = "waiting"
    /\ entry[c] \in Settled
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ result' = [result EXCEPT ![c] = IF entry[c] = "allow" THEN "ran" ELSE "denied"]
    /\ entry' = [entry EXCEPT ![c] = "none"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, atClient, wire, sent, stopped, allowed, card, others, parent>>

\* The call has an outcome, so its card ends once with that outcome: the
\* child's runtime reports an allowed call's end or a denial, and the run's
\* end settles a card whose call never ran.
FinishCard(c) ==
    /\ FinishCards
    /\ card[c] = "pending" /\ result[c] # "none"
    /\ card' = [card EXCEPT ![c] = IF result[c] = "ran" THEN "completed" ELSE "failed"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, others, parent>>

----------------------------------------------------------------------------
(* The client and the reader thread.                                       *)

\* The client answers a request it shows. The answer is on the wire.
ClientSend(c, a) ==
    /\ atClient[c]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, sent, stopped, result, allowed, card, others, parent>>

\* A client that ignores $/cancel_request answers a request fx withdrew.
LateSend(c, a) ==
    /\ sent[c] /\ ~atClient[c] /\ wire[c] = "none"
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, sent, stopped, result, allowed, card, others, parent>>

\* handleClientResponse: an answer settles an open entry; an answer whose
\* entry is gone or already settled is dropped, with a trace line.
Deliver(c) ==
    /\ wire[c] # "none"
    /\ wire' = [wire EXCEPT ![c] = "none"]
    /\ IF entry[c] = "open"
         THEN /\ entry' = [entry EXCEPT ![c] = wire[c]]
              /\ allowed' = [allowed EXCEPT ![c] = allowed[c] \/ wire[c] = "allow"]
         ELSE UNCHANGED <<entry, allowed>>
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, atClient, sent, stopped, result, card, others, parent>>

\* Another subagent, not modeled one by one, asks while the gate is open: its
\* request takes a slot, or is refused at once when none is left for it.
OtherAsk ==
    /\ Route = "host" /\ OthersMayAsk
    /\ gate = "open" /\ Used < ChildLimit /\ others < Capacity
    /\ others' = others + 1
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, parent>>

\* The client answers one of those requests.
OtherAnswer ==
    /\ others > 0
    /\ others' = others - 1
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, parent>>

----------------------------------------------------------------------------
(* The parent's prompt, the user, and the parent's stop.                  *)

\* Shut the gate: cancel every open subagent entry and withdraw its request.
CloseGate ==
    /\ gate' = "closed"
    /\ entry' = [c \in Children |-> IF entry[c] = "open" THEN "cancelled" ELSE entry[c]]
    /\ atClient' = [c \in Children |-> FALSE]

\* The prompt ends once no subagent is working or waiting and no other request
\* is open.
PromptEnd ==
    /\ prompt = "open"
    /\ \A c \in Children : child[c] = "done"
    /\ others = 0 /\ parent # "open"
    /\ prompt' = "closed"
    /\ CloseGate
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed, card, others, parent>>

\* session/cancel: the prompt ends now, with subagents still running. Every
\* open request of every kind is cancelled.
Cancel ==
    /\ prompt = "open"
    /\ prompt' = "closed"
    /\ CloseGate
    /\ others' = 0
    /\ parent' = IF parent = "open" THEN "done" ELSE parent
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed, card>>

\* A later session/prompt starts its thread. The gate opens as it starts.
Reopen ==
    /\ prompt = "closed"
    /\ prompts < MaxPrompts
    /\ prompt' = "open"
    /\ gate' = "open"
    /\ prompts' = prompts + 1
    /\ UNCHANGED <<child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

\* A later session/prompt whose thread cannot start. The gate was opened first;
\* with SpawnClosesGate it is shut again, and without it it stays open with no
\* prompt to close it.
StartFails ==
    /\ prompt = "closed"
    /\ prompts < MaxPrompts
    /\ prompts' = prompts + 1
    /\ gate' = IF SpawnClosesGate THEN "closed" ELSE "open"
    /\ UNCHANGED <<prompt, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>

\* The parent stops a subagent, or its host shuts down.
Stop(c) ==
    /\ ~stopped[c]
    /\ child[c] # "done"
    /\ stopped' = [stopped EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, result, allowed, card, others, parent>>

\* The wait on the client polls the subagent's cancel flag.
StopWait(c) ==
    /\ Route = "host" /\ StopCancelsWait
    /\ stopped[c] /\ child[c] = "waiting" /\ entry[c] = "open"
    /\ entry' = [entry EXCEPT ![c] = "cancelled"]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, wire, sent, stopped, result, allowed, card, others, parent>>

\* Before the change a stop reached the worker's wait (cancelApprovalTurn).
WorkerStop(c) ==
    /\ Route = "worker"
    /\ stopped[c] /\ child[c] = "waiting"
    /\ Deny(c)
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>

\* The parent's own permission request, through the same registry. It fails
\* when no slot is left, which ends the person's whole turn.
ParentAsk ==
    /\ prompt = "open" /\ parent = "none"
    /\ parent' = IF Used < Capacity THEN "open" ELSE "failed"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others>>

\* The client answers it.
ParentAnswer ==
    /\ parent = "open"
    /\ parent' = "done"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others>>

----------------------------------------------------------------------------

FxStep(c) ==
    \/ Ask(c) \/ Finish(c) \/ Begin(c) \/ CheckGate(c) \/ InsertChecked(c) \/ Send(c)
    \/ WaitOnWorker(c) \/ NoHost(c) \/ Decide(c) \/ FinishCard(c) \/ Deliver(c)
    \/ StopWait(c) \/ WorkerStop(c)

Next ==
    \/ \E c \in Children : FxStep(c)
    \/ \E c \in Children, a \in Answers : ClientSend(c, a) \/ LateSend(c, a)
    \/ \E c \in Children : Stop(c)
    \/ PromptEnd \/ Cancel \/ Reopen \/ StartFails
    \/ OtherAsk \/ OtherAnswer \/ ParentAsk \/ ParentAnswer

\* fx's own steps are fair; the user, the parent's stop, and the client are
\* not, so a client may never answer.
FxFair ==
    /\ \A c \in Children :
        /\ WF_vars(Ask(c) \/ Finish(c))
        /\ WF_vars(Begin(c)) /\ WF_vars(CheckGate(c)) /\ WF_vars(InsertChecked(c))
        /\ WF_vars(Send(c))
        /\ WF_vars(WaitOnWorker(c)) /\ WF_vars(NoHost(c))
        /\ WF_vars(Decide(c)) /\ WF_vars(FinishCard(c)) /\ WF_vars(Deliver(c))
        /\ WF_vars(StopWait(c)) /\ WF_vars(WorkerStop(c))
    /\ WF_vars(PromptEnd)

Spec == Init /\ [][Next]_vars /\ FxFair

\* A client that answers every request it shows.
SpecAnswered ==
    /\ Spec
    /\ \A c \in Children : WF_vars(\E a \in Answers : ClientSend(c, a))
    /\ WF_vars(OtherAnswer) /\ WF_vars(ParentAnswer)

----------------------------------------------------------------------------
(* What must hold.                                                         *)

\* An action runs only after an allow for its own open request: a cancelled,
\* error, malformed, or unknown answer, and a late one, never allow it.
NoRunWithoutAllow == \A c \in Children : result[c] = "ran" => allowed[c]

\* No subagent request is shown at the client while no prompt is open.
NoStrandedRequest == prompt = "closed" => \A c \in Children : ~atClient[c]

\* A request the client shows is one fx still waits on: a request written
\* after its cancel went out is withdrawn again.
ShownRequestIsOpen == \A c \in Children : atClient[c] => entry[c] = "open"

\* Once the prompt closes, every subagent's wait ends, answered or not.
CloseEndsWait ==
    \A c \in Children : (prompt = "closed" /\ child[c] = "waiting") ~> (child[c] # "waiting")

\* A stop ends a subagent's wait, answered or not.
StopEndsWait ==
    \A c \in Children : (stopped[c] /\ child[c] = "waiting") ~> (child[c] # "waiting")

\* With a client that answers what it is sent, every prompt ends.
PromptEnds == (prompt = "open") ~> (prompt = "closed")

\* A card is announced, and once its call has an outcome it ends.
CardEnds ==
    \A c \in Children : (card[c] = "pending" /\ result[c] # "none") ~> (card[c] \in FinalCards)

\* An ended card never changes: it ends once.
CardFinalIsFinal ==
    [][\A c \in Children : card[c] \in FinalCards => card'[c] = card[c]]_vars

\* The card shows the call's real outcome: completed only for a call that ran.
CardMatchesResult ==
    \A c \in Children : card[c] \in FinalCards => ((card[c] = "completed") <=> (result[c] = "ran"))

\* The id each call's card and request carry. Every conversation numbers its
\* calls from call_1, and the parent's own card for the subagent call has one
\* too.
CardId(c) == IF PrefixIds THEN <<c, "call_1">> ELSE <<"call_1">>
ParentCardId == <<"call_1">>

\* No two cards in the session share an id.
UniqueIds ==
    \A c \in Children : card[c] # "none" =>
        /\ CardId(c) # ParentCardId
        /\ \A d \in Children : (d # c /\ card[d] # "none") => CardId(c) # CardId(d)

\* The parent's own request always finds a slot.
ParentNeverStarved == parent # "failed"
=============================================================================
