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
(*    (SpawnClosesGate): its thread never runs to close it. It must also   *)
(*    close the steering it opened ("steerCloses", SteeringEnded).         *)
(*  - The request has steps: the insert, the announcement of the call's    *)
(*    card as pending, then the write. A cancel can land between them; the *)
(*    request is then written after its $/cancel_request went out, so it   *)
(*    is withdrawn again after the write (ResendCancel). The other kinds   *)
(*    of request that fx sends on a turn (a host tool, a journal flush, an *)
(*    elicitation) have the same gap and the same repair (Kinds, and the  *)
(*    kinds in Fixed; NoStaleRequest).                                     *)
(*  - The card ends once, with the call's real status (FinishCards): the   *)
(*    child's runtime reports the call's end, and the run's end settles    *)
(*    a card no call ended. A subagent's call ids carry its child id and   *)
(*    the call's order ("seq"), since every conversation numbers its       *)
(*    calls from one, and one run's model can repeat an id (PrefixIds,     *)
(*    OneRun, UniqueIds). The order is kept for the session, per child,    *)
(*    not per run ("sessionSeq"): a child's second run (Track "runs")      *)
(*    repeats its model's ids too.                                         *)
(*  - The prompt's response is its own step (Track "responses"). A card    *)
(*    update after it breaks the protocol, so the prompt's end closes     *)
(*    every card still open, under the lock the children's card updates   *)
(*    take, before it answers ("closeCards"), and a card announced after   *)
(*    that is refused ("cardGate"): NoCardChangeAfterResponse.             *)
(*  - A refusal reads as its cause (Track "causes", "carryCause"): the     *)
(*    prompt is closed, the subagent was stopped, or the registry is full, *)
(*    not as noninteractive mode, and not as the person's denial. A        *)
(*    stopped worker's wait refuses too ("stopRefuses"): ReadsTrue.        *)
(*  - The parent's own request can find its registry entry gone (Track     *)
(*    "gone"). Its wait then ends with a refusal that reads as closed, as  *)
(*    a subagent's does ("parentRefuses"), and not as the person's denial: *)
(*    ParentReadsTrue.                                                     *)
(*  - A request leaves its trace line once, where a cancel or a stop        *)
(*    settles it (Track "traces"). The cleanup after the failed wait finds *)
(*    the entry gone and says nothing ("quietDrain"): TraceOnce, and the   *)
(*    cancel's own line stays (CancelTraced).                              *)
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
          Capacity,        \* entries the registry holds, for every kind of request
          OneRun,          \* TRUE: the modeled children are calls of one subagent run
          Track,           \* parts modeled, to bound the state space: a subset of
                           \* {"responses", "causes", "gone", "runs", "traces"}
          Fixed,           \* repairs in effect: a subset of {"seq", "sessionSeq", "closeCards",
                           \* "cardGate", "carryCause", "stopRefuses", "steerCloses",
                           \* "parentRefuses", "quietDrain"}, of the wrong repairs
                           \* {"openSeq", "silentCancel"}, and of Kinds
          Kinds            \* other request kinds modeled one each: a subset of
                           \* {"host_tool", "journal", "elicitation"}

ASSUME Route \in {"host", "worker", "none"}
ASSUME AtomicGate \in BOOLEAN /\ StopCancelsWait \in BOOLEAN
ASSUME FinishCards \in BOOLEAN /\ SpawnClosesGate \in BOOLEAN /\ PrefixIds \in BOOLEAN
ASSUME ReserveSlot \in BOOLEAN /\ ResendCancel \in BOOLEAN /\ OthersMayAsk \in BOOLEAN
ASSUME OneRun \in BOOLEAN
ASSUME Track \subseteq {"responses", "causes", "gone", "runs", "traces"}
ASSUME Kinds \subseteq {"host_tool", "journal", "elicitation"}
ASSUME Fixed \subseteq ({"seq", "sessionSeq", "closeCards", "cardGate", "carryCause", "stopRefuses", "steerCloses", "parentRefuses", "quietDrain", "openSeq", "silentCancel"} \cup Kinds)
ASSUME MaxPrompts \in Nat \ {0}
ASSUME Capacity \in Nat \ {0}

Responses == "responses" \in Track
Causes == "causes" \in Track
Gone == "gone" \in Track
Runs == "runs" \in Track
Lines == "traces" \in Track

Answers == {"allow", "reject", "garbage", "error"}
Settled == Answers \cup {"cancelled", "stopCancelled"}
FinalCards == {"completed", "failed"}
\* Why a request was refused or went unanswered, and what the model reads.
Reasons == {"closed", "stopped", "full", "noninteractive", "user_denied"}
KStates == {"none", "gap", "gapCancelled", "shown", "stale", "withdrawn", "answered", "cancelled"}

VARIABLES
    prompt,    \* "open" | "closed": the parent's session/prompt
    gate,      \* "open" | "closed": subagent_asks_open
    prompts,   \* how many prompts have started
    child,     \* "working" | "asking" | "announcing" | "sending" | "waiting" | "done"
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
    parent,    \* the parent's own request: "none" | "open" | "done" | "failed", or
               \* "goneClosed" | "goneDenied": its entry was gone, and what its model reads
    seq,       \* the call's order among its run's announced calls, set with its card
    closer,    \* the prompt's end closing cards: "idle" | "closing" (holds the card lock) | "done"
    response,  \* the current prompt's response: "none" | "sent"
    truth,     \* why the subagent's request was refused or cancelled
    reads,     \* what the subagent's model reads about it
    steer,     \* "open" | "closed": the session's steering
    kreq,      \* each other kind's request, by Kinds
    lines      \* the trace lines each subagent request left for how it ended

oldVars == <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
nv == <<seq, closer, response, truth, reads, steer, kreq, lines>>
vars == <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent, seq, closer, response, truth, reads, steer, kreq, lines>>

TypeOK ==
    /\ prompt \in {"open", "closed"}
    /\ gate \in {"open", "closed"}
    /\ prompts \in 1..MaxPrompts
    /\ child \in [Children -> {"working", "asking", "announcing", "sending", "waiting", "done"}]
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
    /\ parent \in {"none", "open", "done", "failed", "goneClosed", "goneDenied"}
    /\ seq \in [Children -> 0..Cardinality(Children)]
    /\ closer \in {"idle", "closing", "done"}
    /\ response \in {"none", "sent"}
    /\ truth \in [Children -> {"none"} \cup Reasons]
    /\ reads \in [Children -> {"none"} \cup Reasons]
    /\ steer \in {"open", "closed"}
    /\ kreq \in [Kinds -> KStates]
    /\ lines \in [Children -> 0..2]

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
    /\ seq = [c \in Children |-> 0]
    /\ closer = "idle"
    /\ response = IF Responses THEN "none" ELSE "sent"
    /\ truth = [c \in Children |-> "none"]
    /\ reads = [c \in Children |-> "none"]
    /\ steer = "open"
    /\ kreq = [k \in Kinds |-> "none"]
    /\ lines = [c \in Children |-> 0]

\* Slots in use: every subagent's entry, the anonymous ones, and the parent's.
Used ==
    Cardinality({c \in Children : entry[c] # "none"}) + others + (IF parent = "open" THEN 1 ELSE 0)

\* How many entries a subagent's request may find before it is refused.
ChildLimit == IF ReserveSlot THEN Capacity - 1 ELSE Capacity

\* The subagent child a modeled call belongs to, whose id leads its card's, and
\* the run it belongs to. With OneRun the modeled children are calls of one run
\* of one child; with Runs, calls in separate runs of one child.
ChildOf(c) == IF OneRun \/ Runs THEN "r1" ELSE c
RunOf(c) == IF OneRun THEN "r1" ELSE c

\* The calls whose cards an order counts: the run's own, or, kept for the
\* session ("sessionSeq"), every run of the child. How many of them have
\* announced a card.
Scope(c) == IF "sessionSeq" \in Fixed THEN ChildOf(c) ELSE RunOf(c)
Announced(s) == Cardinality({d \in Children : Scope(d) = s /\ card[d] # "none"})

\* A wrong repair, "openSeq": the order counts the child's cards that are
\* still open, so a card that ended frees its order.
OpenCards(c) == Cardinality({d \in Children : ChildOf(d) = ChildOf(c) /\ card[d] = "pending"})

\* The order the call's card takes.
Seq(c) == IF "openSeq" \in Fixed THEN OpenCards(c) + 1 ELSE Announced(Scope(c)) + 1

\* The trace lines a request leaves where a cancel or a stop settles it: the
\* registry's cancel and the stop's withdrawal each leave one. "silentCancel",
\* a wrong repair, silences them with the cleanup's line.
CancelLine == IF Lines /\ "silentCancel" \notin Fixed THEN 1 ELSE 0

\* The cleanup after a wait that took a cancelled or withdrawn entry drains an
\* entry that is gone, and leaves a line for it unless "quietDrain".
DrainLine == IF Lines /\ "quietDrain" \notin Fixed THEN 1 ELSE 0

\* What the model reads when fx refuses with `why`, up front (`when` "begin")
\* or in answer to a wait that ended ("wait"). A refusal that carries its
\* cause reads it. Without that, a refusal up front reads as noninteractive
\* mode, which is false in fx acp, and one that ends a wait reads as the
\* person's denial.
Read(why, when) ==
    IF "carryCause" \in Fixed \/ why \in {"noninteractive", "user_denied"} THEN why
    ELSE IF when = "begin" THEN "noninteractive" ELSE "user_denied"

\* Records the refusal's cause and what the model reads, when causes are modeled.
Cause(c, why, read) ==
    /\ truth' = IF Causes THEN [truth EXCEPT ![c] = why] ELSE truth
    /\ reads' = IF Causes THEN [reads EXCEPT ![c] = read] ELSE reads

\* The subagent's call ends with a refusal. Callers account for the other
\* variables.
Deny(c, why, read) ==
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ result' = [result EXCEPT ![c] = "denied"]
    /\ Cause(c, why, read)

----------------------------------------------------------------------------
(* The subagent's own turn.                                                *)

\* It reaches an action that needs approval.
Ask(c) ==
    /\ child[c] = "working"
    /\ ~stopped[c]
    /\ child' = [child EXCEPT ![c] = "asking"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

\* It ends without one, or a stop ends it first.
Finish(c) ==
    /\ child[c] = "working"
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

\* The design: the gated insert. An open gate, a subagent not stopped, and a
\* free slot: insert the entry. With responses modeled the card is announced
\* in a step of its own (Announce); otherwise in this one. A refusal is at
\* once, with no card. A stop that lands after the subagent read its stop
\* flag is a Stop after this step.
Begin(c) ==
    /\ Route = "host" /\ AtomicGate
    /\ child[c] = "asking"
    /\ IF gate = "open" /\ ~stopped[c] /\ Used < ChildLimit
         THEN /\ entry' = [entry EXCEPT ![c] = "open"]
              /\ IF Responses
                   THEN /\ child' = [child EXCEPT ![c] = "announcing"]
                        /\ UNCHANGED <<card, seq>>
                   ELSE /\ child' = [child EXCEPT ![c] = "sending"]
                        /\ card' = [card EXCEPT ![c] = "pending"]
                        /\ seq' = [seq EXCEPT ![c] = Seq(c)]
              /\ UNCHANGED <<result, truth, reads>>
         ELSE /\ LET why == IF stopped[c] THEN "stopped" ELSE IF gate = "closed" THEN "closed" ELSE "full"
                 IN Deny(c, why, Read(why, "begin"))
              /\ UNCHANGED <<entry, card, seq>>
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, atClient, wire, sent, stopped, allowed, others, parent>>
    /\ UNCHANGED <<closer, response, steer, kreq, lines>>

\* The card, announced under the card lock. Once the prompt's end has closed
\* the cards, the request is refused (cardGate), cancelled and forgotten as
\* a request that was never written is.
Announce(c) ==
    /\ Responses /\ Route = "host" /\ AtomicGate
    /\ child[c] = "announcing"
    /\ closer # "closing"
    /\ IF "cardGate" \in Fixed /\ closer = "done"
         THEN /\ entry' = [entry EXCEPT ![c] = "none"]
              /\ Deny(c, "closed", Read("closed", "begin"))
              /\ UNCHANGED <<card, seq>>
         ELSE /\ card' = [card EXCEPT ![c] = "pending"]
              /\ seq' = [seq EXCEPT ![c] = Seq(c)]
              /\ child' = [child EXCEPT ![c] = "sending"]
              /\ UNCHANGED <<entry, result, truth, reads>>
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, atClient, wire, sent, stopped, allowed, others, parent>>
    /\ UNCHANGED <<closer, response, steer, kreq, lines>>

\* A planted bug: the gate is read in one step ...
CheckGate(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ ~sawOpen[c]
    /\ IF gate = "open" /\ ~stopped[c] /\ Used < ChildLimit
         THEN /\ sawOpen' = [sawOpen EXCEPT ![c] = TRUE]
              /\ UNCHANGED <<child, result, truth, reads>>
         ELSE /\ LET why == IF stopped[c] THEN "stopped" ELSE IF gate = "closed" THEN "closed" ELSE "full"
                 IN Deny(c, why, Read(why, "begin"))
              /\ UNCHANGED sawOpen
    /\ UNCHANGED <<prompt, gate, prompts, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, steer, kreq, lines>>

\* ... and the request inserted in a later one.
InsertChecked(c) ==
    /\ Route = "host" /\ ~AtomicGate
    /\ child[c] = "asking" /\ sawOpen[c]
    /\ sawOpen' = [sawOpen EXCEPT ![c] = FALSE]
    /\ entry' = [entry EXCEPT ![c] = "open"]
    /\ card' = [card EXCEPT ![c] = "pending"]
    /\ seq' = [seq EXCEPT ![c] = Seq(c)]
    /\ child' = [child EXCEPT ![c] = "sending"]
    /\ UNCHANGED <<prompt, gate, prompts, atClient, wire, sent, stopped, result, allowed, others, parent>>
    /\ UNCHANGED <<closer, response, truth, reads, steer, kreq, lines>>

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
    /\ UNCHANGED nv

\* Before the change: the subagent waits on its own worker, which nothing
\* in ACP reads.
WaitOnWorker(c) ==
    /\ Route = "worker"
    /\ child[c] = "asking"
    /\ child' = [child EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

\* fx ask: no prompter for subagents, so refuse at once. The refusal reads as
\* what it is: noninteractive mode.
NoHost(c) ==
    /\ Route = "none"
    /\ child[c] = "asking"
    /\ Deny(c, "noninteractive", "noninteractive")
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, steer, kreq, lines>>

\* The waiting subagent reads its settled entry and removes it. An answer is
\* the client's. A cancel, which the prompt's end or the host made, or a
\* stop, is not the person's denial.
Decide(c) ==
    /\ child[c] = "waiting"
    /\ entry[c] \in Settled
    /\ child' = [child EXCEPT ![c] = "done"]
    /\ result' = [result EXCEPT ![c] = IF entry[c] = "allow" THEN "ran" ELSE "denied"]
    /\ entry' = [entry EXCEPT ![c] = "none"]
    /\ IF entry[c] = "allow"
         THEN UNCHANGED <<truth, reads>>
         ELSE LET why == IF entry[c] = "stopCancelled" THEN "stopped"
                         ELSE IF entry[c] = "cancelled" THEN "closed"
                         ELSE "user_denied"
              IN Cause(c, why, Read(why, "wait"))
    \* A wait that took a cancelled or withdrawn entry fails, and the cleanup
    \* after it drains the entry it finds gone.
    /\ lines' = [lines EXCEPT ![c] = IF entry[c] \in {"cancelled", "stopCancelled"}
                                      THEN lines[c] + DrainLine ELSE lines[c]]
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, atClient, wire, sent, stopped, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, steer, kreq>>

\* The call has an outcome, so its card ends once with that outcome: the
\* child's runtime reports an allowed call's end or a denial, and the run's
\* end settles a card whose call never ran. It takes the card lock.
FinishCard(c) ==
    /\ FinishCards
    /\ closer # "closing"
    /\ card[c] = "pending" /\ result[c] # "none"
    /\ card' = [card EXCEPT ![c] = IF result[c] = "ran" THEN "completed" ELSE "failed"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, others, parent>>
    /\ UNCHANGED nv

----------------------------------------------------------------------------
(* The client and the reader thread.                                       *)

\* The client answers a request it shows. The answer is on the wire.
ClientSend(c, a) ==
    /\ atClient[c]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

\* A client that ignores $/cancel_request answers a request fx withdrew.
LateSend(c, a) ==
    /\ sent[c] /\ ~atClient[c] /\ wire[c] = "none"
    /\ wire' = [wire EXCEPT ![c] = a]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

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
    /\ UNCHANGED nv

\* Another subagent, not modeled one by one, asks while the gate is open: its
\* request takes a slot, or is refused at once when none is left for it.
OtherAsk ==
    /\ Route = "host" /\ OthersMayAsk
    /\ gate = "open" /\ Used < ChildLimit /\ others < Capacity
    /\ others' = others + 1
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, parent>>
    /\ UNCHANGED nv

\* The client answers one of those requests.
OtherAnswer ==
    /\ others > 0
    /\ others' = others - 1
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, parent>>
    /\ UNCHANGED nv

----------------------------------------------------------------------------
(* The parent's prompt, the user, and the parent's stop.                  *)

\* Shut the gate: cancel every open subagent entry and withdraw its request.
CloseGate ==
    /\ gate' = "closed"
    /\ entry' = [c \in Children |-> IF entry[c] = "open" THEN "cancelled" ELSE entry[c]]
    /\ atClient' = [c \in Children |-> FALSE]
    /\ lines' = [c \in Children |-> IF entry[c] = "open" THEN lines[c] + CancelLine ELSE lines[c]]

\* The prompt ends once no subagent is working or waiting and no other request
\* is open. The steering ends with it. With Runs, a run that has not asked yet
\* is a later run of the child, which the prompt does not wait for.
PromptEnd ==
    /\ prompt = "open"
    /\ \A c \in Children : child[c] = "done" \/ (Runs /\ child[c] = "working")
    /\ others = 0 /\ parent # "open"
    /\ \A k \in Kinds : kreq[k] \notin {"gap", "shown"}
    /\ prompt' = "closed"
    /\ steer' = "closed"
    /\ CloseGate
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, truth, reads, kreq>>

\* session/cancel: the prompt ends now, with subagents still running. Every
\* open request of every kind is cancelled, and the steering ends.
Cancel ==
    /\ prompt = "open"
    /\ prompt' = "closed"
    /\ steer' = "closed"
    /\ CloseGate
    /\ others' = 0
    /\ parent' = IF parent = "open" THEN "done" ELSE parent
    /\ kreq' = [k \in Kinds |-> IF kreq[k] = "gap" THEN "gapCancelled"
                                ELSE IF kreq[k] = "shown" THEN "cancelled"
                                ELSE kreq[k]]
    /\ UNCHANGED <<prompts, child, sawOpen, wire, sent, stopped, result, allowed, card>>
    /\ UNCHANGED <<seq, closer, response, truth, reads>>

\* A later session/prompt starts its thread, once the earlier prompt has
\* answered. The gate and the steering open as it starts.
Reopen ==
    /\ prompt = "closed" /\ response = "sent"
    /\ prompts < MaxPrompts
    /\ prompt' = "open"
    /\ gate' = "open"
    /\ prompts' = prompts + 1
    /\ closer' = "idle"
    /\ response' = IF Responses THEN "none" ELSE "sent"
    /\ steer' = "open"
    /\ UNCHANGED <<child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, truth, reads, kreq, lines>>

\* A later session/prompt whose thread cannot start. The gate and the steering
\* were opened first; with SpawnClosesGate the gate is shut again and with
\* "steerCloses" the steering, and without them they stay open with no prompt
\* to close them.
StartFails ==
    /\ prompt = "closed" /\ response = "sent"
    /\ prompts < MaxPrompts
    /\ prompts' = prompts + 1
    /\ gate' = IF SpawnClosesGate THEN "closed" ELSE "open"
    /\ closer' = IF Responses /\ SpawnClosesGate THEN "done" ELSE "idle"
    /\ steer' = IF "steerCloses" \in Fixed THEN "closed" ELSE "open"
    /\ UNCHANGED <<prompt, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, response, truth, reads, kreq, lines>>

\* The parent stops a subagent, or its host shuts down.
Stop(c) ==
    /\ ~stopped[c]
    /\ child[c] # "done"
    /\ stopped' = [stopped EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, result, allowed, card, others, parent>>
    /\ UNCHANGED nv

\* The wait on the client polls the subagent's cancel flag.
StopWait(c) ==
    /\ Route = "host" /\ StopCancelsWait
    /\ stopped[c] /\ child[c] = "waiting" /\ entry[c] = "open"
    /\ entry' = [entry EXCEPT ![c] = "stopCancelled"]
    /\ atClient' = [atClient EXCEPT ![c] = FALSE]
    /\ lines' = [lines EXCEPT ![c] = lines[c] + CancelLine]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, truth, reads, steer, kreq>>

\* Before the change a stop reached the worker's wait (cancelApprovalTurn).
\* The wait ends with a refusal that names the stop (stopRefuses); it used
\* to return a plain deny, which reads as the person's denial.
WorkerStop(c) ==
    /\ Route = "worker"
    /\ stopped[c] /\ child[c] = "waiting"
    /\ Deny(c, "stopped", IF "stopRefuses" \in Fixed THEN "stopped" ELSE "user_denied")
    /\ UNCHANGED <<prompt, gate, prompts, sawOpen, entry, atClient, wire, sent, stopped, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, steer, kreq, lines>>

\* The parent's own permission request, through the same registry. It fails
\* when no slot is left, which ends the person's whole turn.
ParentAsk ==
    /\ prompt = "open" /\ parent = "none"
    /\ parent' = IF Used < Capacity THEN "open" ELSE "failed"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others>>
    /\ UNCHANGED nv

\* The client answers it.
ParentAnswer ==
    /\ parent = "open"
    /\ parent' = "done"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others>>
    /\ UNCHANGED nv

\* The parent's request finds no entry in the registry: nothing settled it. Its
\* wait ends with a refusal that reads as closed ("parentRefuses"); it used to
\* return a plain deny, which reads as the person's denial. The slot is free.
ParentGone ==
    /\ Gone /\ parent = "open"
    /\ parent' = IF "parentRefuses" \in Fixed THEN "goneClosed" ELSE "goneDenied"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others>>
    /\ UNCHANGED nv

----------------------------------------------------------------------------
(* The prompt thread's end: the closer, then the response.                *)

\* The prompt thread takes the card lock and closes the cards one by one. No
\* card is announced or ends meanwhile.
BeginClose ==
    /\ Responses /\ "closeCards" \in Fixed
    /\ prompt = "closed" /\ response = "none" /\ closer = "idle"
    /\ closer' = "closing"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, response, truth, reads, steer, kreq, lines>>

\* One open card ends, whatever its call was doing: the prompt's end settles it.
CloseCard(c) ==
    /\ Responses /\ "closeCards" \in Fixed
    /\ closer = "closing" /\ card[c] = "pending"
    /\ card' = [card EXCEPT ![c] = "failed"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, others, parent>>
    /\ UNCHANGED nv

\* No card is open: the lock is let go, and the cards stay shut.
EndClose ==
    /\ closer = "closing" /\ \A c \in Children : card[c] # "pending"
    /\ closer' = "done"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, response, truth, reads, steer, kreq, lines>>

\* The response. With "closeCards" it comes after the closer; without, it
\* does not wait for an open card.
Respond ==
    /\ Responses
    /\ prompt = "closed" /\ response = "none"
    /\ "closeCards" \in Fixed => closer = "done"
    /\ response' = "sent"
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, truth, reads, steer, kreq, lines>>

----------------------------------------------------------------------------
(* Other kinds of request: a host tool, a journal flush, an elicitation.  *)

\* The request is inserted in the registry, while the prompt is open.
KInsert(k) ==
    /\ prompt = "open" /\ kreq[k] = "none"
    /\ kreq' = [kreq EXCEPT ![k] = "gap"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, truth, reads, steer, lines>>

\* The write. A request cancelled since its insert had its $/cancel_request
\* sent ahead of it; with the kind in Fixed it is withdrawn again after the
\* write, and without it the client is left showing a request nobody waits for.
KWrite(k) ==
    /\ kreq[k] \in {"gap", "gapCancelled"}
    /\ kreq' = [kreq EXCEPT ![k] = IF kreq[k] = "gap" THEN "shown"
                                    ELSE IF k \in Fixed THEN "withdrawn" ELSE "stale"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, truth, reads, steer, lines>>

\* The client answers it.
KAnswer(k) ==
    /\ kreq[k] = "shown"
    /\ kreq' = [kreq EXCEPT ![k] = "answered"]
    /\ UNCHANGED <<prompt, gate, prompts, child, sawOpen, entry, atClient, wire, sent, stopped, result, allowed, card, others, parent>>
    /\ UNCHANGED <<seq, closer, response, truth, reads, steer, lines>>

----------------------------------------------------------------------------

FxStep(c) ==
    \/ Ask(c) \/ Finish(c) \/ Begin(c) \/ Announce(c) \/ CheckGate(c) \/ InsertChecked(c) \/ Send(c)
    \/ WaitOnWorker(c) \/ NoHost(c) \/ Decide(c) \/ FinishCard(c) \/ Deliver(c)
    \/ StopWait(c) \/ WorkerStop(c)

Next ==
    \/ \E c \in Children : FxStep(c)
    \/ \E c \in Children, a \in Answers : ClientSend(c, a) \/ LateSend(c, a)
    \/ \E c \in Children : Stop(c) \/ CloseCard(c)
    \/ PromptEnd \/ Cancel \/ Reopen \/ StartFails
    \/ BeginClose \/ EndClose \/ Respond
    \/ OtherAsk \/ OtherAnswer \/ ParentAsk \/ ParentAnswer \/ ParentGone
    \/ \E k \in Kinds : KInsert(k) \/ KWrite(k) \/ KAnswer(k)

\* fx's own steps are fair; the user, the parent's stop, and the client are
\* not, so a client may never answer.
FxFair ==
    /\ \A c \in Children :
        /\ WF_vars(Ask(c) \/ Finish(c))
        /\ WF_vars(Begin(c)) /\ WF_vars(Announce(c))
        /\ WF_vars(CheckGate(c)) /\ WF_vars(InsertChecked(c))
        /\ WF_vars(Send(c))
        /\ WF_vars(WaitOnWorker(c)) /\ WF_vars(NoHost(c))
        /\ WF_vars(Decide(c)) /\ WF_vars(FinishCard(c)) /\ WF_vars(Deliver(c))
        /\ WF_vars(StopWait(c)) /\ WF_vars(WorkerStop(c))
        /\ WF_vars(CloseCard(c))
    /\ WF_vars(PromptEnd)
    /\ WF_vars(BeginClose) /\ WF_vars(EndClose) /\ WF_vars(Respond)

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
\* Where the prompt's end is modeled it also settles a card whose call ran,
\* as cancelled, so a failed card may show a call that ran.
CardMatchesResult ==
    \A c \in Children : card[c] \in FinalCards =>
        IF Responses THEN (card[c] = "completed" => result[c] = "ran")
        ELSE ((card[c] = "completed") <=> (result[c] = "ran"))

\* The id each call's card and request carry. Every conversation numbers its
\* calls from call_1, one run's model can repeat an id, and the parent's own
\* card for the subagent call has one too.
IdRule == IF ~PrefixIds THEN "model" ELSE IF "seq" \in Fixed THEN "child_seq" ELSE "child"
CardId(c) ==
    CASE IdRule = "model" -> <<"call_1">>
      [] IdRule = "child" -> <<ChildOf(c), "call_1">>
      [] OTHER -> <<ChildOf(c), seq[c], "call_1">>
ParentCardId == <<"call_1">>

\* No two cards in the session share an id.
UniqueIds ==
    \A c \in Children : card[c] # "none" =>
        /\ CardId(c) # ParentCardId
        /\ \A d \in Children : (d # c /\ card[d] # "none") => CardId(c) # CardId(d)

\* The parent's own request always finds a slot.
ParentNeverStarved == parent # "failed"

\* A parent's request whose entry is gone is not read as the person's denial.
ParentReadsTrue == parent # "goneDenied"

\* No card changes once the prompt has answered: an update after the response
\* breaks ACP's prompt turn.
NoCardChangeAfterResponse ==
    [][(Responses /\ response = "sent") => card' = card]_vars

\* Once a prompt has closed, its response is sent.
ResponseSent ==
    (Responses /\ prompt = "closed" /\ response = "none") ~> (response = "sent")

\* A refusal reads as its real cause.
ReadsTrue == \A c \in Children : reads[c] # "none" => reads[c] = truth[c]

\* Another kind's request is never left shown at the client after its cancel.
NoStaleRequest == \A k \in Kinds : kreq[k] # "stale"

\* No steering stays open with no prompt to end it.
SteeringEnded == prompt = "closed" => steer = "closed"

\* A request leaves at most one trace line for how it ended: the cleanup after
\* its failed wait drains an entry that is gone, and says nothing of it.
TraceOnce == Lines => \A c \in Children : lines[c] <= 1

\* A request that a cancel or a stop settled, and that was written, leaves its
\* one line.
CancelTraced ==
    Lines => \A c \in Children :
        (child[c] = "done" /\ sent[c] /\ truth[c] \in {"closed", "stopped"}) => lines[c] = 1
=============================================================================
