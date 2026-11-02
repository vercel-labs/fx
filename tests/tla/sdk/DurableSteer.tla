----------------------------- MODULE DurableSteer -----------------------------
(***************************************************************************)
(* Where the messages a user sends to one libfx session end up.            *)
(*                                                                         *)
(* The user sends a first prompt and then steering messages. Each message  *)
(* is placed in the model's context of exactly one turn: it starts a turn  *)
(* of its own, or it joins a turn. A turn runs model requests: while one   *)
(* streams text or reasoning the turn is in `gen`, once the model streams  *)
(* a tool call's arguments it is in `args`, and while the tool runs it is  *)
(* in `tool`. These rules come from the fx CLI:                            *)
(*                                                                         *)
(* - A steer sent in `gen` cuts the reply short: the request stops and the *)
(*   turn goes on with the steer in its next request (Interrupt).          *)
(* - A steer sent in `args` or `tool` waits for the tool, then joins the   *)
(*   same turn in the request after the result. A steer waiting when a     *)
(*   reply ends continues the turn.                                        *)
(* - A cancel ends the turn. Steers that were waiting and never reached    *)
(*   the model run next, the first as a turn and the rest joining it       *)
(*   (HandBack).                                                           *)
(* - A steer sent while a turn waits to start joins that turn              *)
(*   (JoinBeforeStart). With no turn at all, it starts one.                *)
(* - Sending a message again with the same id adds nothing (Dedupe).       *)
(*                                                                         *)
(* Turns after the first start in the same delivery as the turn before    *)
(* them. A turn that waits with no worker running starts when a delivery   *)
(* takes the session (Start), so a message sent before then has not been   *)
(* seen by any worker. At a deadline the running request is cut off and   *)
(* the turn continues in the next delivery (Handoff); steers it had taken  *)
(* but not placed go into the resumed request.                             *)
(*                                                                         *)
(* Each rule has a constant. Setting one to FALSE gives the behavior libfx *)
(* had before this model, and each witness config shows the property that *)
(* rule protects then fails. `act` names each step so that                 *)
(* tests/tla/drivers/drive-steer.mjs can drive the real code along any path*)
(* of the state graph and compare every state.                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Steers,          \* the steering messages the user may send
    MaxTools,        \* tool calls the model may make in the session
    MaxHandoffs,     \* deadline handoffs
    MaxCancels,      \* user cancels
    Retries,         \* whether the client may send a steer again with its id
    Interrupt,       \* a steer in `gen` cuts the reply short
    HandBack,        \* a cancel hands waiting steers back to run next
    JoinBeforeStart, \* a steer sent while a turn waits to start joins it
    Dedupe           \* a repeated id adds nothing

ASSUME Interrupt \in BOOLEAN /\ HandBack \in BOOLEAN
ASSUME JoinBeforeStart \in BOOLEAN /\ Dedupe \in BOOLEAN /\ Retries \in BOOLEAN

P == "p"
Msgs == {P} \cup Steers
None == "none"
States == {"waiting", "running", "end", "cancelled"}

VARIABLES
    sent,      \* the messages the user has sent, in order
    turns,     \* every turn in order: who owns it, its state, and the
               \* messages in its model context (for a waiting turn, the
               \* messages it will start with)
    phase,     \* what the running turn waits on: "idle", "gen", "args", "tool"
    queue,     \* steers the running turn took and has not placed yet
    worker,    \* whether a delivery holds the session
    retried,   \* steers the client sent a second time
    dup,       \* steers whose second send became a second message
    preStart,  \* steers sent while a turn waited to start
    tools,     \* tool calls so far
    handoffs,  \* deadline handoffs so far
    cancels,   \* cancels so far
    act        \* the step that led here

vars == <<sent, turns, phase, queue, worker, retried, dup, preStart, tools, handoffs, cancels, act>>

Range(s) == {s[i] : i \in DOMAIN s}

TypeOK ==
    /\ sent \in Seq(Msgs)
    /\ \A i \in DOMAIN turns : turns[i] \in [owner: Msgs, state: States, ctx: SUBSET Msgs]
    /\ phase \in {"idle", "gen", "args", "tool"}
    /\ queue \in Seq(Steers)
    /\ worker \in BOOLEAN
    /\ retried \subseteq Steers /\ dup \subseteq Steers /\ preStart \subseteq Steers
    /\ tools \in 0..MaxTools /\ handoffs \in 0..MaxHandoffs /\ cancels \in 0..MaxCancels
    /\ act \in [name: {"Init", "Send", "Retry", "Start", "ModelText", "ToolArgs", "ToolCall",
                       "ToolEnd", "Cancel", "Handoff"},
                m: Msgs \cup {None}]

Init ==
    /\ sent = <<>>
    /\ turns = <<>>
    /\ phase = "idle"
    /\ queue = <<>>
    /\ worker = FALSE
    /\ retried = {} /\ dup = {} /\ preStart = {}
    /\ tools = 0 /\ handoffs = 0 /\ cancels = 0
    /\ act = [name |-> "Init", m |-> None]

RunningAt == {i \in DOMAIN turns : turns[i].state = "running"}
WaitingAt == {i \in DOMAIN turns : turns[i].state = "waiting"}
Running == RunningAt # {}
Run == CHOOSE i \in RunningAt : TRUE
FirstWaiting == CHOOSE i \in WaitingAt : \A j \in WaitingAt : i <= j

\* The running turn's context with the steers it waited on placed in it.
Placed(t, steers) == [t EXCEPT !.ctx = t.ctx \cup Range(steers)]

\* New waiting turns for steers handed back or sent with no turn to join:
\* the first owns a turn, and the rest join it when JoinBeforeStart holds.
NewTurns(steers) ==
    IF steers = <<>> THEN <<>>
    ELSE IF JoinBeforeStart
         THEN <<[owner |-> steers[1], state |-> "waiting", ctx |-> Range(steers)]>>
         ELSE [k \in 1..Len(steers) |-> [owner |-> steers[k], state |-> "waiting", ctx |-> {steers[k]}]]

\* The running turn ends `how`; steers handed back wait after it. The next
\* waiting turn, if any, starts in the same delivery.
Finish(how, back) ==
    LET ended == [turns EXCEPT ![Run].state = how] \o NewTurns(back)
        waiting == {i \in DOMAIN ended : ended[i].state = "waiting"}
        next == CHOOSE i \in waiting : \A j \in waiting : i <= j
    IN IF waiting # {}
       THEN /\ turns' = [ended EXCEPT ![next].state = "running"]
            /\ phase' = "gen"
            /\ worker' = TRUE
       ELSE /\ turns' = ended
            /\ phase' = "idle"
            /\ worker' = FALSE

\* The user sends a message it has not sent before. The first prompt comes
\* first. A steer goes to the running turn, joins the turn waiting to start,
\* or starts a turn of its own.
Send(m) ==
    /\ m \notin Range(sent)
    /\ (m = P) = (sent = <<>>)
    /\ sent' = Append(sent, m)
    /\ IF m = P
          THEN /\ turns' = <<[owner |-> P, state |-> "waiting", ctx |-> {P}]>>
               /\ UNCHANGED <<phase, queue, preStart>>
          ELSE IF Running
          THEN /\ IF phase = "gen" /\ Interrupt
                     \* the reply stops and the next request carries m
                     THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], <<m>>)]
                          /\ UNCHANGED queue
                     ELSE /\ queue' = Append(queue, m)
                          /\ UNCHANGED turns
               /\ UNCHANGED <<phase, preStart>>
          ELSE IF WaitingAt # {}
          THEN /\ preStart' = preStart \cup {m}
               /\ turns' = IF JoinBeforeStart
                              THEN [turns EXCEPT ![FirstWaiting].ctx = @ \cup {m}]
                              ELSE turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<phase, queue>>
          ELSE /\ turns' = turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<phase, queue, preStart>>
    /\ UNCHANGED <<worker, retried, dup, tools, handoffs, cancels>>
    /\ act' = [name |-> "Send", m |-> m]

\* The client sends a steer again with the same id, as a retry after a lost
\* response would. Without Dedupe it becomes a second message wherever the
\* first one is placed.
Retry(m) ==
    /\ Retries
    /\ m \in Steers /\ m \in Range(sent) /\ m \notin retried
    /\ retried' = retried \cup {m}
    /\ dup' = IF Dedupe THEN dup ELSE dup \cup {m}
    /\ UNCHANGED <<sent, turns, phase, queue, worker, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "Retry", m |-> m]

\* A delivery takes the session and starts the first waiting turn.
Start ==
    /\ ~worker
    /\ WaitingAt # {}
    /\ turns' = [turns EXCEPT ![FirstWaiting].state = "running"]
    /\ phase' = "gen"
    /\ worker' = TRUE
    /\ UNCHANGED <<sent, queue, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "Start", m |-> None]

\* The model's reply ends with text. Steers waiting on it continue the
\* turn; otherwise the turn ends.
ModelText ==
    /\ phase = "gen"
    /\ IF queue # <<>>
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
               /\ UNCHANGED <<phase, worker>>
          ELSE Finish("end", <<>>)
    /\ queue' = <<>>
    /\ UNCHANGED <<sent, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ModelText", m |-> None]

\* The model starts streaming a tool call's arguments.
ToolArgs ==
    /\ phase = "gen"
    /\ tools < MaxTools
    /\ phase' = "args"
    /\ UNCHANGED <<sent, turns, queue, worker, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolArgs", m |-> None]

\* The tool call's arguments end and the tool starts.
ToolCall ==
    /\ phase = "args"
    /\ phase' = "tool"
    /\ tools' = tools + 1
    /\ UNCHANGED <<sent, turns, queue, worker, retried, dup, preStart, handoffs, cancels>>
    /\ act' = [name |-> "ToolCall", m |-> None]

\* The tool returns; the next request carries its result and every steer
\* that waited on it.
ToolEnd ==
    /\ phase = "tool"
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolEnd", m |-> None]

\* The user cancels the running turn. Steers it never placed run next.
Cancel ==
    /\ Running
    /\ cancels < MaxCancels
    /\ Finish("cancelled", IF HandBack THEN queue ELSE <<>>)
    /\ queue' = <<>>
    /\ cancels' = cancels + 1
    /\ UNCHANGED <<sent, retried, dup, preStart, tools, handoffs>>
    /\ act' = [name |-> "Cancel", m |-> None]

\* The deadline cuts off the request in flight and the next delivery
\* continues the turn; the resumed request carries the steers it had taken.
Handoff ==
    /\ phase \in {"gen", "args"}
    /\ handoffs < MaxHandoffs
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ handoffs' = handoffs + 1
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, tools, cancels>>
    /\ act' = [name |-> "Handoff", m |-> None]

Next ==
    \/ \E m \in Msgs : Send(m) \/ Retry(m)
    \/ Start \/ ModelText \/ ToolArgs \/ ToolCall \/ ToolEnd \/ Cancel \/ Handoff

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* The turns whose context holds m, and how many copies of m each holds.
Holders(m) == {i \in DOMAIN turns : turns[i].state # "waiting" /\ m \in turns[i].ctx}
Times(m) == Cardinality(Holders(m)) * (IF m \in dup THEN 2 ELSE 1)

\* No message reaches the model twice.
AtMostOnce == \A m \in Msgs : Times(m) <= 1

\* With nothing running or waiting, every message sent is in exactly one
\* turn.
Quiescent == ~Running /\ WaitingAt = {}
NothingLost == Quiescent => \A i \in DOMAIN sent : Times(sent[i]) = 1

\* Turns start in the order their owners were sent.
SentIndex(m) == CHOOSE i \in DOMAIN sent : sent[i] = m
InOrder == \A i, j \in DOMAIN turns : i < j => SentIndex(turns[i].owner) < SentIndex(turns[j].owner)

\* A reply never streams while a steer waits on it.
NoSteerWaitsOnReply == phase = "gen" => queue = <<>>

\* A steer sent while a turn waited to start joins it.
PreStartJoins == \A s \in preStart : \A i \in DOMAIN turns : turns[i].owner # s

=============================================================================
