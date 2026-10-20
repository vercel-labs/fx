----------------------------- MODULE DurableSteer -----------------------------
(***************************************************************************)
(* Where the messages a user sends to one libfx session end up.            *)
(*                                                                         *)
(* The user sends a first prompt and then steering messages. Each message  *)
(* is placed in the model's context of exactly one turn: it starts a turn  *)
(* of its own, or it joins a turn. A turn runs model requests: while one   *)
(* streams text or reasoning the turn is in `gen`, once the model streams  *)
(* a tool call's arguments it is in `args`, and while the tool runs it is  *)
(* in `tool`. A reply can also end in a tool call whose arguments the      *)
(* model never streamed; until that tool starts, the turn is in `call`.    *)
(* These rules come from the fx CLI:                                       *)
(*                                                                         *)
(* - A steer sent in `gen` cuts the reply short: the request stops and the *)
(*   turn goes on with the steer in its next request (Interrupt).          *)
(* - A steer sent in `args` or `tool` waits for the tool, then joins the   *)
(*   same turn in the request after the result. So does one sent in `call` *)
(*   (CallWaits): the reply it could cut short has ended. A steer waiting  *)
(*   when a reply ends continues the turn.                                 *)
(* - A cancel ends the turn. Steers that were waiting and never reached    *)
(*   the model run next, the first as a turn and the rest joining it       *)
(*   (HandBack).                                                           *)
(* - A steer sent while a turn waits to start joins that turn              *)
(*   (JoinBeforeStart). With no turn at all, it starts one.                *)
(* - Sending a message again with the same id adds nothing (Dedupe).       *)
(*                                                                         *)
(* A steer is stored in the session's log, and the running turn has it     *)
(* only once its worker reads the log, which a poll or another server's    *)
(* write need not make it do in time. A steer the worker hears of as it is *)
(* stored, as of a write on its own server, is read at once while a reply  *)
(* streams; any other waits unread until the worker reads the log (Read),  *)
(* in every phase. Before a tool's result reaches the model the worker     *)
(* reads the log itself (ReadAfterTool), so the request after the result   *)
(* carries every steer stored before it (API-53). Before a turn whose      *)
(* reply ended with no tool call ends, the worker reads the log again      *)
(* (ReadAtEnd), so a steer sent while that reply streamed continues the    *)
(* turn (API-50) instead of running as a turn of its own.                  *)
(*                                                                         *)
(* That read is the turn's last. Once it found nothing, the turn is        *)
(* `ending` until the record that ends it lands (EndLands), and its engine *)
(* takes no more steers. A steer stored in that window is too late for the *)
(* turn: the worker may read it and hand it on, but the turn never takes   *)
(* it, so it stays stored, and it runs as the next turn, the first such    *)
(* steer owning it and the rest joining it (LateRunsNext). A cancel or a   *)
(* deadline in that window ends the turn as its end lands, and the same    *)
(* steers run next.                                                        *)
(*                                                                         *)
(* Turns after the first start in the same delivery as the turn before     *)
(* them. A turn that waits with no worker running starts when a delivery   *)
(* takes the session (Start), so a message sent before then has not been   *)
(* seen by any worker. At a deadline the running request, or a call that   *)
(* waits for its intent to be stored, is cut off and the turn continues in *)
(* the next delivery (Handoff). Steers it had taken but not placed, and    *)
(* the ones stored since, go into the resumed request; a call that is safe *)
(* to run twice runs again first, and they wait for it.                    *)
(*                                                                         *)
(* Each rule has a constant. Setting one to FALSE gives the behavior libfx *)
(* had before this model, or for LateRunsNext a worker that counts a steer *)
(* it handed on as taken, and each witness config shows the property that  *)
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
    CallWaits,       \* a steer in `call` waits for the tool
    HandBack,        \* a cancel hands waiting steers back to run next
    JoinBeforeStart, \* a steer sent while a turn waits to start joins it
    Dedupe,          \* a repeated id adds nothing
    ReadAfterTool,   \* the worker reads stored steers before a tool's result goes to the model
    ReadAtEnd,       \* the worker reads stored steers before a turn ends after a reply
    LateRunsNext     \* a steer stored after that read stays stored until the turn has ended

ASSUME Interrupt \in BOOLEAN /\ CallWaits \in BOOLEAN /\ HandBack \in BOOLEAN
ASSUME JoinBeforeStart \in BOOLEAN /\ Dedupe \in BOOLEAN /\ Retries \in BOOLEAN
ASSUME ReadAfterTool \in BOOLEAN /\ ReadAtEnd \in BOOLEAN /\ LateRunsNext \in BOOLEAN

P == "p"
Msgs == {P} \cup Steers
None == "none"
States == {"waiting", "running", "end", "cancelled"}

VARIABLES
    sent,       \* the messages the user has sent, in order
    turns,      \* every turn in order: who owns it, its state, and the
                \* messages in its model context (for a waiting turn, the
                \* messages it will start with)
    phase,      \* what the running turn waits on: "idle", "gen", "args",
                \* "call", "tool", or "ending" for its end to land
    queue,      \* steers the running turn took and has not placed yet
    unread,     \* steers stored for the running turn that its worker has not read
    worker,     \* whether a delivery holds the session
    retried,    \* steers the client sent a second time
    dup,        \* steers whose second send became a second message
    preStart,   \* steers sent while a turn waited to start
    alone,      \* steers sent with no turn running or waiting
    handedBack, \* steers a cancel handed back to run next
    lateAfter,  \* for each steer sent while a turn was `ending`, that turn's
                \* index; 0 for every other steer
    tools,      \* tool calls so far
    handoffs,   \* deadline handoffs so far
    cancels,    \* cancels so far
    act         \* the step that led here

vars == <<sent, turns, phase, queue, unread, worker, retried, dup, preStart, alone, handedBack,
          lateAfter, tools, handoffs, cancels, act>>

Range(s) == {s[i] : i \in DOMAIN s}

TypeOK ==
    /\ sent \in Seq(Msgs)
    /\ \A i \in DOMAIN turns : turns[i] \in [owner: Msgs, state: States, ctx: SUBSET Msgs]
    /\ phase \in {"idle", "gen", "args", "call", "tool", "ending"}
    /\ queue \in Seq(Steers)
    /\ unread \in Seq(Steers)
    /\ worker \in BOOLEAN
    /\ retried \subseteq Steers /\ dup \subseteq Steers /\ preStart \subseteq Steers
    /\ alone \subseteq Steers /\ handedBack \subseteq Steers
    /\ lateAfter \in [Steers -> 0..Len(turns)]
    /\ tools \in 0..MaxTools /\ handoffs \in 0..MaxHandoffs /\ cancels \in 0..MaxCancels
    /\ act \in [name: {"Init", "Send", "Retry", "Start", "Read", "ModelText", "EndLands", "ToolArgs",
                       "ReplyCall", "ToolCall", "ToolEnd", "Cancel", "Handoff"},
                m: Msgs \cup {None}]

Init ==
    /\ sent = <<>>
    /\ turns = <<>>
    /\ phase = "idle"
    /\ queue = <<>>
    /\ unread = <<>>
    /\ worker = FALSE
    /\ retried = {} /\ dup = {} /\ preStart = {}
    /\ alone = {} /\ handedBack = {}
    /\ lateAfter = [s \in Steers |-> 0]
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
\* or starts a turn of its own. One for the running turn waits unread until
\* its worker reads the log, as one another server stores does; while its
\* reply streams and nothing waits unread, the worker may hear of it at once
\* and read it then, as it does a steer stored on its own server. One sent
\* while the turn is `ending` is late: it waits unread, from either server,
\* since the turn takes it from no read.
Send(m) ==
    /\ m \notin Range(sent)
    /\ (m = P) = (sent = <<>>)
    /\ sent' = Append(sent, m)
    /\ IF m = P
          THEN /\ turns' = <<[owner |-> P, state |-> "waiting", ctx |-> {P}]>>
               /\ UNCHANGED <<phase, queue, unread, worker, preStart, alone>>
          ELSE IF Running /\ phase = "call" /\ ~CallWaits
          \* as before CallWaits: the steer takes the ended reply's
          \* interrupt, its tool never starts, and the turn ends with every
          \* waiting steer and this one handed back to run next
          THEN /\ Finish("end", queue \o unread \o <<m>>)
               /\ queue' = <<>>
               /\ unread' = <<>>
               /\ UNCHANGED <<preStart, alone>>
          ELSE IF Running
          THEN /\ \/ /\ phase = "gen" /\ unread = <<>>
                     /\ IF Interrupt
                           \* the reply stops and the next request carries m
                           THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], <<m>>)]
                                /\ UNCHANGED queue
                           ELSE /\ queue' = Append(queue, m)
                                /\ UNCHANGED turns
                     /\ UNCHANGED unread
                  \/ /\ unread' = Append(unread, m)
                     /\ UNCHANGED <<turns, queue>>
               /\ UNCHANGED <<phase, worker, preStart, alone>>
          ELSE IF WaitingAt # {}
          THEN /\ preStart' = preStart \cup {m}
               /\ turns' = IF JoinBeforeStart
                              THEN [turns EXCEPT ![FirstWaiting].ctx = @ \cup {m}]
                              ELSE turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<phase, queue, unread, worker, alone>>
          ELSE /\ turns' = turns \o NewTurns(<<m>>)
               /\ alone' = alone \cup {m}
               /\ UNCHANGED <<phase, queue, unread, worker, preStart>>
    \* one sent while the running turn's end lands is late for that turn
    /\ lateAfter' = IF m # P /\ Running /\ phase = "ending" THEN [lateAfter EXCEPT ![m] = Run] ELSE lateAfter
    /\ UNCHANGED <<retried, dup, handedBack, tools, handoffs, cancels>>
    /\ act' = [name |-> "Send", m |-> m]

\* The client sends a steer again with the same id, as a retry after a lost
\* response would. Without Dedupe it becomes a second message wherever the
\* first one is placed.
Retry(m) ==
    /\ Retries
    /\ m \in Steers /\ m \in Range(sent) /\ m \notin retried
    /\ retried' = retried \cup {m}
    /\ dup' = IF Dedupe THEN dup ELSE dup \cup {m}
    /\ UNCHANGED <<sent, turns, phase, queue, unread, worker, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "Retry", m |-> m]

\* A delivery takes the session and starts the first waiting turn.
Start ==
    /\ ~worker
    /\ WaitingAt # {}
    /\ turns' = [turns EXCEPT ![FirstWaiting].state = "running"]
    /\ phase' = "gen"
    /\ worker' = TRUE
    /\ UNCHANGED <<sent, queue, unread, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "Start", m |-> None]

\* The worker reads the log, from a poll or a write it hears of, and the
\* running turn takes every steer stored since: one cuts a streaming reply
\* short, and others wait for the tool. While the turn is `ending` it takes
\* none, so a read then changes nothing, unless the worker counts the steers
\* it handed on as taken, as it would without LateRunsNext.
Read ==
    /\ unread # <<>>
    /\ phase # "ending" \/ ~LateRunsNext
    /\ IF phase = "gen" /\ Interrupt
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], unread)]
               /\ UNCHANGED queue
          ELSE /\ queue' = queue \o unread
               /\ UNCHANGED turns
    /\ unread' = <<>>
    /\ UNCHANGED <<sent, phase, worker, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "Read", m |-> None]

\* The model's reply ends with text. Steers waiting on it continue the
\* turn. With ReadAtEnd the worker reads the log before the turn ends, so
\* the steers stored for it that it had not read continue it too. Otherwise
\* the turn's end starts to land, and steers its worker never read run next.
ModelText ==
    /\ phase = "gen"
    /\ LET late == IF ReadAtEnd THEN unread ELSE <<>>
       IN IF queue \o late # <<>>
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue \o late)]
               /\ unread' = IF ReadAtEnd THEN <<>> ELSE unread
               /\ UNCHANGED phase
          ELSE /\ phase' = "ending"
               /\ UNCHANGED <<turns, unread>>
    /\ queue' = <<>>
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "ModelText", m |-> None]

\* The record that ends the turn lands. The steers stored and never taken
\* run next, the first as a turn and the rest joining it, in the same
\* delivery. Without LateRunsNext the ones the worker read while the turn
\* was ending count as taken by it, though it never placed them.
EndLands ==
    /\ phase = "ending"
    /\ Finish("end", unread)
    /\ queue' = <<>>
    /\ unread' = <<>>
    /\ UNCHANGED <<sent, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "EndLands", m |-> None]

\* The model starts streaming a tool call's arguments.
ToolArgs ==
    /\ phase = "gen"
    /\ tools < MaxTools
    /\ phase' = "args"
    /\ UNCHANGED <<sent, turns, queue, unread, worker, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolArgs", m |-> None]

\* The model's reply ends in a tool call it streamed no arguments for. The
\* tool has not started.
ReplyCall ==
    /\ phase = "gen"
    /\ tools < MaxTools
    /\ phase' = "call"
    /\ UNCHANGED <<sent, turns, queue, unread, worker, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "ReplyCall", m |-> None]

\* The tool call is complete and the tool starts.
ToolCall ==
    /\ phase \in {"args", "call"}
    /\ phase' = "tool"
    /\ tools' = tools + 1
    /\ UNCHANGED <<sent, turns, queue, unread, worker, retried, dup, preStart, alone, handedBack, lateAfter, handoffs, cancels>>
    /\ act' = [name |-> "ToolCall", m |-> None]

\* The tool returns; the next request carries its result and every steer
\* that waited on it. With ReadAfterTool the worker reads the log before
\* the result goes on, so that includes the steers stored while the tool
\* ran that it had not read.
ToolEnd ==
    /\ phase = "tool"
    /\ IF ReadAfterTool
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue \o unread)]
               /\ unread' = <<>>
          ELSE /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
               /\ UNCHANGED unread
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, alone, handedBack, lateAfter, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolEnd", m |-> None]

\* The user cancels the running turn. Steers it never placed run next, and
\* so do the ones its worker never read, which no turn took. A turn that is
\* `ending` ends cancelled when the cancel reaches its engine before the
\* engine writes the record that ends it, and otherwise as that record says
\* (`DurableSession.tla` LateCancel).
Cancel ==
    /\ Running
    /\ cancels < MaxCancels
    /\ LET back == (IF HandBack THEN queue ELSE <<>>) \o unread
       IN /\ \E how \in IF phase = "ending" THEN {"end", "cancelled"} ELSE {"cancelled"} : Finish(how, back)
          /\ handedBack' = handedBack \cup Range(back)
    /\ queue' = <<>>
    /\ unread' = <<>>
    /\ cancels' = cancels + 1
    /\ UNCHANGED <<sent, retried, dup, preStart, alone, lateAfter, tools, handoffs>>
    /\ act' = [name |-> "Cancel", m |-> None]

\* The deadline cuts off the request in flight, or a call that waits in
\* `call` for its intent to be stored, and the next delivery continues the
\* turn with the steers it had taken and the ones stored since, which that
\* delivery reads. A cut-off request runs again and carries them. A cut-off
\* call with effects never runs: the model hears it may have partly run,
\* in a request that carries them. A call that is safe to run twice runs
\* again, and they wait for it. A turn that is `ending` has nothing left to
\* cut off: it ends as its end lands, and the next delivery runs the steers
\* stored since, as EndLands does.
Handoff ==
    /\ phase \in {"gen", "args", "call", "ending"}
    /\ handoffs < MaxHandoffs
    /\ IF phase = "ending"
          THEN /\ Finish("end", unread)
               /\ queue' = <<>>
               /\ UNCHANGED tools
          ELSE /\ \/ /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue \o unread)]
                     /\ queue' = <<>>
                     /\ phase' = "gen"
                     /\ UNCHANGED tools
                  \/ /\ phase = "call"
                     /\ queue' = queue \o unread
                     /\ phase' = "tool"
                     /\ tools' = tools + 1
                     /\ UNCHANGED turns
               /\ UNCHANGED worker
    /\ unread' = <<>>
    /\ handoffs' = handoffs + 1
    /\ UNCHANGED <<sent, retried, dup, preStart, alone, handedBack, lateAfter, cancels>>
    /\ act' = [name |-> "Handoff", m |-> None]

Next ==
    \/ \E m \in Msgs : Send(m) \/ Retry(m)
    \/ Start \/ Read \/ ModelText \/ EndLands \/ ToolArgs \/ ReplyCall \/ ToolCall \/ ToolEnd \/ Cancel \/ Handoff

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

\* API-53: a steer reaches the model no later than the running turn's next
\* request. The request right after a tool's result carries every steer
\* stored before it, whether or not the worker had read it.
SteerInNextRequest == act.name = "ToolEnd" => unread = <<>>

\* A steer sent while a turn waited to start joins it.
PreStartJoins == \A s \in preStart : \A i \in DOMAIN turns : turns[i].owner # s

\* The steers sent while a turn's end was landing, after its last read.
Late == {s \in Steers : lateAfter[s] > 0}

\* A steer owns a turn only when no turn ran or waited as it was sent, a
\* cancel handed it back, or it came after the running turn's last read: a
\* steer sent to a running turn before then is never parked to run as a
\* turn of its own.
NoParkedSteer == \A i \in DOMAIN turns : turns[i].owner \in {P} \cup alone \cup handedBack \cup Late

\* Where that cut-off falls, the one place a steer sent during a turn does
\* not steer it (API-50, API-51): a steer sent after the running turn's last
\* read, while its end lands, never joins that turn. Once the turn has ended,
\* the steer is in the next turn, which it owns or joins, and in no other: it
\* is never lost (DUR-23) and reaches the model once.
LateSteerRunsNext ==
    \A s \in Late :
        LET k == lateAfter[s]
        IN /\ s \notin turns[k].ctx
           /\ turns[k].state \in {"end", "cancelled"} =>
                 /\ k + 1 \in DOMAIN turns
                 /\ s \in turns[k + 1].ctx
                 /\ \A i \in DOMAIN turns : i # k + 1 => s \notin turns[i].ctx

=============================================================================
