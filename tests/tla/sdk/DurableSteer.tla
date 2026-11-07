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
(* A steer sent while a turn runs is stored in the session's log first, by *)
(* the process that runs the turn (Send) or by another one (Store). The    *)
(* running turn's worker hears of a steer another process stored only     *)
(* when it reads the log (Apply), on a poll or after an append, and a read *)
(* takes the entries stored before it, in log order. A steer stored and   *)
(* not read yet when the reply ends starts a turn of its own, the first   *)
(* stored owning it. With HandOver, the log gives each steer this process *)
(* stores to the running turn's worker as it lands, so Send places it at  *)
(* once, before the sender hears it was stored. With ReadFirst, it does so *)
(* only when the worker has read every entry before it; a steer stored    *)
(* behind one the worker has not read waits for the read, so the turn     *)
(* takes steers in the order the log stored them.                         *)
(*                                                                         *)
(* This process writes the log too: its worker stores the turn's records.  *)
(* Such a write takes its slot and lands later (Write, Land). A steer this  *)
(* process stores meanwhile can land first in the slot after it, and its   *)
(* watcher then sees an entry before it unread. With SlotOrder, an input   *)
(* this process stores while one of its own writes is in flight waits for  *)
(* that write to land, so the watchers hear of both in slot order and the  *)
(* steer is still handed over; the worker's own records never wait. The    *)
(* wait ends at the poll interval (Expire), and the steer then waits for a *)
(* read.                                                                   *)
(*                                                                         *)
(* Each rule has a constant. Setting one to FALSE gives the behavior libfx *)
(* had before this model, or without that rule, and each witness config   *)
(* shows the property that rule protects then fails. `act` names each     *)
(* step so that tests/tla/drivers/drive-steer.mjs can drive the real code  *)
(* along any path of the state graph and compare every state.             *)
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
    Dedupe,          \* a repeated id adds nothing
    HandOver,        \* a steer this process stores reaches its worker as it lands
    ReadFirst,       \* ...only when the worker has read every entry before it
    SlotOrder,       \* this process's entries reach its watchers in slot order
    MaxWrites        \* records the worker writes while a turn runs

ASSUME Interrupt \in BOOLEAN /\ HandBack \in BOOLEAN
ASSUME JoinBeforeStart \in BOOLEAN /\ Dedupe \in BOOLEAN /\ Retries \in BOOLEAN
ASSUME HandOver \in BOOLEAN /\ ReadFirst \in BOOLEAN /\ SlotOrder \in BOOLEAN
ASSUME MaxWrites \in Nat

P == "p"
Msgs == {P} \cup Steers
None == "none"
States == {"waiting", "running", "end", "cancelled"}

VARIABLES
    sent,      \* the messages the user has sent, in the order the log stored them
    turns,     \* every turn in order: who owns it, its state, and the
               \* messages in its model context, in the order they joined
               \* (for a waiting turn, the messages it will start with)
    phase,     \* what the running turn waits on: "idle", "gen", "args", "tool"
    queue,     \* steers the running turn took and has not placed yet
    log,       \* steers stored while the turn runs that its worker has not
               \* read, in log order
    away,      \* steers another process stored
    behind,    \* steers this process stored while an entry before them was
               \* unread
    writing,   \* whether a record the worker writes has its slot and has not
               \* landed
    writes,    \* records the worker has written so far
    held,      \* steers in `log` this process stored that wait for that write
               \* to land
    late,      \* steers whose wait ran out before the write landed
    worker,    \* whether a delivery holds the session
    retried,   \* steers the client sent a second time
    dup,       \* steers whose second send became a second message
    preStart,  \* steers sent while a turn waited to start
    tools,     \* tool calls so far
    handoffs,  \* deadline handoffs so far
    cancels,   \* cancels so far
    missed,    \* steers this process stored, with nothing unread before them,
               \* that a tool result's request went out without
    atTool,    \* the running turn's context in the request that carried the
               \* last tool result
    act        \* the step that led here

vars == <<sent, turns, phase, queue, log, away, behind, writing, writes, held, late, worker,
          retried, dup, preStart, tools, handoffs, cancels, missed, atTool, act>>
wvars == <<writing, writes, held, late>>

Range(s) == {s[i] : i \in DOMAIN s}

TypeOK ==
    /\ sent \in Seq(Msgs)
    /\ \A i \in DOMAIN turns : turns[i] \in [owner: Msgs, state: States, ctx: Seq(Msgs)]
    /\ phase \in {"idle", "gen", "args", "tool"}
    /\ queue \in Seq(Steers)
    /\ log \in Seq(Steers)
    /\ away \subseteq Steers /\ behind \subseteq Steers
    /\ writing \in BOOLEAN /\ writes \in 0..MaxWrites
    /\ held \subseteq Steers /\ late \subseteq Steers
    /\ worker \in BOOLEAN
    /\ retried \subseteq Steers /\ dup \subseteq Steers /\ preStart \subseteq Steers
    /\ tools \in 0..MaxTools /\ handoffs \in 0..MaxHandoffs /\ cancels \in 0..MaxCancels
    /\ missed \subseteq Steers
    /\ atTool \in Seq(Msgs)
    /\ act \in [name: {"Init", "Send", "Store", "Retry", "Start", "Apply", "Write", "Land", "Expire",
                       "ModelText", "ToolArgs", "ToolCall", "ToolEnd", "Cancel", "Handoff"},
                m: Msgs \cup {None}]

Init ==
    /\ sent = <<>>
    /\ turns = <<>>
    /\ phase = "idle"
    /\ queue = <<>>
    /\ log = <<>>
    /\ away = {} /\ behind = {}
    /\ writing = FALSE /\ writes = 0 /\ held = {} /\ late = {}
    /\ worker = FALSE
    /\ retried = {} /\ dup = {} /\ preStart = {}
    /\ tools = 0 /\ handoffs = 0 /\ cancels = 0
    /\ missed = {}
    /\ atTool = <<>>
    /\ act = [name |-> "Init", m |-> None]

RunningAt == {i \in DOMAIN turns : turns[i].state = "running"}
WaitingAt == {i \in DOMAIN turns : turns[i].state = "waiting"}
Running == RunningAt # {}
Run == CHOOSE i \in RunningAt : TRUE
FirstWaiting == CHOOSE i \in WaitingAt : \A j \in WaitingAt : i <= j

\* The running turn's context with the steers it waited on placed in it, in
\* the order it took them.
Placed(t, steers) == [t EXCEPT !.ctx = t.ctx \o steers]

\* The running turn takes `steers`, in order: in `gen` they cut the reply
\* short and the next request carries them (Interrupt); otherwise they wait
\* for the tool.
Take(steers) ==
    IF phase = "gen" /\ Interrupt
    THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], steers)]
         /\ UNCHANGED queue
    ELSE /\ queue' = queue \o steers
         /\ UNCHANGED turns

\* New waiting turns for steers handed back or sent with no turn to join:
\* the first owns a turn, and the rest join it when JoinBeforeStart holds.
NewTurns(steers) ==
    IF steers = <<>> THEN <<>>
    ELSE IF JoinBeforeStart
         THEN <<[owner |-> steers[1], state |-> "waiting", ctx |-> steers]>>
         ELSE [k \in 1..Len(steers) |-> [owner |-> steers[k], state |-> "waiting", ctx |-> <<steers[k]>>]]

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

\* The user sends a message it has not sent before, from the process that
\* runs the turn. The first prompt comes first. A steer sent while a turn
\* runs reaches the turn as it is stored (HandOver), unless an entry before
\* it is unread (ReadFirst); then it waits in the log for the worker's read
\* (Apply). While a record the worker writes is in flight, the steer waits
\* for it to land (SlotOrder), behind the steers already waiting on it;
\* without SlotOrder it may take the slot after the record and see the
\* record unread. With no turn running it joins the turn waiting to start,
\* or starts a turn of its own, as the worker folds the log when the turn
\* starts.
Send(m) ==
    /\ m \notin Range(sent)
    /\ (m = P) = (sent = <<>>)
    /\ sent' = Append(sent, m)
    /\ IF m = P
          THEN /\ turns' = <<[owner |-> P, state |-> "waiting", ctx |-> <<P>>]>>
               /\ UNCHANGED <<queue, log, behind, held, preStart>>
          ELSE IF Running /\ HandOver /\ (~ReadFirst \/ (log = <<>> /\ ~writing))
          THEN /\ Take(<<m>>)
               /\ UNCHANGED <<log, behind, held, preStart>>
          ELSE IF Running /\ HandOver /\ writing /\ SlotOrder /\ Range(log) \subseteq held
          THEN /\ log' = Append(log, m)
               /\ held' = held \cup {m}
               /\ UNCHANGED <<turns, queue, behind, preStart>>
          ELSE IF Running /\ HandOver /\ writing /\ ~SlotOrder /\ log = <<>>
          \* Its slot may come before the record's, or after it.
          THEN \/ /\ Take(<<m>>)
                  /\ UNCHANGED <<log, behind, held, preStart>>
               \/ /\ log' = Append(log, m)
                  /\ UNCHANGED <<turns, queue, behind, held, preStart>>
          ELSE IF Running
          THEN /\ log' = Append(log, m)
               /\ behind' = IF log # <<>> THEN behind \cup {m} ELSE behind
               /\ UNCHANGED <<turns, queue, held, preStart>>
          ELSE IF WaitingAt # {}
          THEN /\ preStart' = preStart \cup {m}
               /\ turns' = IF JoinBeforeStart
                              THEN [turns EXCEPT ![FirstWaiting].ctx = Append(@, m)]
                              ELSE turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<queue, log, behind, held>>
          ELSE /\ turns' = turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<queue, log, behind, held, preStart>>
    /\ UNCHANGED <<phase, away, writing, writes, late, worker, retried, dup, tools, handoffs, cancels,
                   missed, atTool>>
    /\ act' = [name |-> "Send", m |-> m]

\* Another process stores a steer while the turn runs; the turn's worker
\* hears of it only when it reads the log. With no turn running, a steer
\* another process stores is a Send: the worker that starts the next turn
\* folds every stored input alike.
Store(m) ==
    /\ m \in Steers /\ m \notin Range(sent)
    /\ Running
    /\ sent' = Append(sent, m)
    /\ log' = Append(log, m)
    /\ away' = away \cup {m}
    /\ UNCHANGED <<turns, phase, queue, behind, wvars, worker, retried, dup, preStart, tools, handoffs,
                   cancels, missed, atTool>>
    /\ act' = [name |-> "Store", m |-> m]

\* The running turn's worker reads the log and takes the steers stored since
\* it last read, in log order. A read takes the entries stored before it, so
\* it may take only the first ones; the rest wait for the next read.
Apply ==
    /\ log # <<>>
    /\ \E k \in 1..Len(log) :
          /\ Take(SubSeq(log, 1, k))
          /\ log' = SubSeq(log, k + 1, Len(log))
          /\ held' = held \ Range(SubSeq(log, 1, k))
    /\ UNCHANGED <<sent, phase, away, behind, writing, writes, late, worker, retried, dup, preStart,
                   tools, handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "Apply", m |-> None]

\* The worker starts writing a record: it has its slot and has not landed.
Write ==
    /\ Running
    /\ ~writing
    /\ writes < MaxWrites
    /\ writing' = TRUE
    /\ writes' = writes + 1
    /\ UNCHANGED <<sent, turns, phase, queue, log, away, behind, held, late, worker, retried, dup,
                   preStart, tools, handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "Write", m |-> None]

\* The record lands. The watchers hear of it, then of the steers that waited
\* on it, in slot order, so the running turn takes them as handed over.
Land ==
    /\ writing
    /\ writing' = FALSE
    /\ IF held # {} /\ Running
          THEN /\ Take(SubSeq(log, 1, Cardinality(held)))
               /\ log' = SubSeq(log, Cardinality(held) + 1, Len(log))
          ELSE UNCHANGED <<turns, queue, log>>
    /\ held' = {}
    /\ UNCHANGED <<sent, phase, away, behind, writes, late, worker, retried, dup, preStart, tools,
                   handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "Land", m |-> None]

\* The record has not landed by the poll interval: the steers that waited on
\* it stop waiting, and the worker's next read takes them.
Expire ==
    /\ held # {}
    /\ late' = late \cup held
    /\ held' = {}
    /\ UNCHANGED <<sent, turns, phase, queue, log, away, behind, writing, writes, worker, retried, dup,
                   preStart, tools, handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "Expire", m |-> None]

\* The client sends a steer again with the same id, as a retry after a lost
\* response would. Without Dedupe it becomes a second message wherever the
\* first one is placed.
Retry(m) ==
    /\ Retries
    /\ m \in Steers /\ m \in Range(sent) /\ m \notin retried
    /\ retried' = retried \cup {m}
    /\ dup' = IF Dedupe THEN dup ELSE dup \cup {m}
    /\ UNCHANGED <<sent, turns, phase, queue, log, away, behind, wvars, worker, preStart, tools,
                   handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "Retry", m |-> m]

\* A delivery takes the session and starts the first waiting turn.
Start ==
    /\ ~worker
    /\ WaitingAt # {}
    /\ turns' = [turns EXCEPT ![FirstWaiting].state = "running"]
    /\ phase' = "gen"
    /\ worker' = TRUE
    /\ UNCHANGED <<sent, queue, log, away, behind, wvars, retried, dup, preStart, tools, handoffs,
                   cancels, missed, atTool>>
    /\ act' = [name |-> "Start", m |-> None]

\* The model's reply ends with text. Steers waiting on it continue the
\* turn; otherwise the turn ends, and steers stored but not read yet start
\* the next turn.
ModelText ==
    /\ phase = "gen"
    /\ IF queue # <<>>
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
               /\ UNCHANGED <<phase, worker, log, held>>
          ELSE /\ Finish("end", log)
               /\ log' = <<>>
               /\ held' = {}
    /\ queue' = <<>>
    /\ UNCHANGED <<sent, away, behind, writing, writes, late, retried, dup, preStart, tools, handoffs,
                   cancels, missed, atTool>>
    /\ act' = [name |-> "ModelText", m |-> None]

\* The model starts streaming a tool call's arguments.
ToolArgs ==
    /\ phase = "gen"
    /\ tools < MaxTools
    /\ phase' = "args"
    /\ UNCHANGED <<sent, turns, queue, log, away, behind, wvars, worker, retried, dup, preStart, tools,
                   handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "ToolArgs", m |-> None]

\* The tool call's arguments end and the tool starts.
ToolCall ==
    /\ phase = "args"
    /\ phase' = "tool"
    /\ tools' = tools + 1
    /\ UNCHANGED <<sent, turns, queue, log, away, behind, wvars, worker, retried, dup, preStart,
                   handoffs, cancels, missed, atTool>>
    /\ act' = [name |-> "ToolCall", m |-> None]

\* The tool returns; the next request carries its result and every steer
\* that waited on it. A steer stored but not read yet misses that request
\* and joins on a later read, cutting the reply short; `missed` records the
\* ones this process stored, whose steer() call had returned, with nothing
\* unread before them and no wait for a record that ran out.
ToolEnd ==
    /\ phase = "tool"
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
    /\ atTool' = turns[Run].ctx \o queue
    /\ missed' = missed \cup (Range(log) \ (away \cup behind \cup held \cup late))
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ UNCHANGED <<sent, log, away, behind, wvars, worker, retried, dup, preStart, tools, handoffs,
                   cancels>>
    /\ act' = [name |-> "ToolEnd", m |-> None]

\* The user cancels the running turn. Steers it never placed run next: those
\* it took when HandBack holds, and those it never read, which the log still
\* holds as untaken, in log order.
Cancel ==
    /\ Running
    /\ cancels < MaxCancels
    /\ Finish("cancelled", IF HandBack THEN queue \o log ELSE log)
    /\ queue' = <<>>
    /\ log' = <<>>
    /\ held' = {}
    /\ cancels' = cancels + 1
    /\ UNCHANGED <<sent, away, behind, writing, writes, late, retried, dup, preStart, tools, handoffs,
                   missed, atTool>>
    /\ act' = [name |-> "Cancel", m |-> None]

\* The deadline cuts off the request in flight and the next delivery
\* continues the turn; the resumed request carries the steers it had taken
\* and those the next worker reads from the log.
Handoff ==
    /\ phase \in {"gen", "args"}
    /\ handoffs < MaxHandoffs
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue \o log)]
    /\ queue' = <<>>
    /\ log' = <<>>
    /\ held' = {}
    /\ phase' = "gen"
    /\ handoffs' = handoffs + 1
    /\ UNCHANGED <<sent, away, behind, writing, writes, late, worker, retried, dup, preStart, tools,
                   cancels, missed, atTool>>
    /\ act' = [name |-> "Handoff", m |-> None]

Next ==
    \/ \E m \in Msgs : Send(m) \/ Store(m) \/ Retry(m)
    \/ Start \/ Apply \/ Write \/ Land \/ Expire
    \/ ModelText \/ ToolArgs \/ ToolCall \/ ToolEnd \/ Cancel \/ Handoff

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* Every message in the turns of `ts`, turn by turn, each turn's in the order
\* they joined it.
RECURSIVE Flat(_)
Flat(ts) == IF ts = <<>> THEN <<>> ELSE Head(ts).ctx \o Flat(Tail(ts))

\* What has reached the model: the turns that started, in order.
Started == SelectSeq(turns, LAMBDA t : t.state # "waiting")

\* How many times m reached the model.
Count(s, m) == Cardinality({i \in DOMAIN s : s[i] = m})
Times(m) == Count(Flat(Started), m) * (IF m \in dup THEN 2 ELSE 1)

\* No message reaches the model twice.
AtMostOnce == \A m \in Msgs : Times(m) <= 1

\* With nothing running or waiting, every message sent is in exactly one
\* turn.
Quiescent == ~Running /\ WaitingAt = {}
NothingLost == Quiescent => \A i \in DOMAIN sent : Times(sent[i]) = 1

\* Turns start in the order their owners were sent.
SentIndex(m) == CHOOSE i \in DOMAIN sent : sent[i] = m
InOrder == \A i, j \in DOMAIN turns : i < j => SentIndex(turns[i].owner) < SentIndex(turns[j].owner)

\* Messages reach the model in the order the log stored them: turn by turn,
\* and within a turn, waiting ones included, in the order they joined it.
AdmissionOrder ==
    LET all == Flat(turns)
    IN \A i, j \in DOMAIN all : i < j => SentIndex(all[i]) < SentIndex(all[j])

\* A reply never streams while a steer waits on it.
NoSteerWaitsOnReply == phase = "gen" => queue = <<>>

\* A steer sent while a turn waited to start joins it.
PreStartJoins == \A s \in preStart : \A i \in DOMAIN turns : turns[i].owner # s

\* A steer the turn's own process stored before a tool returned, with
\* nothing unread before it, is in the request that carries the tool's
\* result.
SteerJoinsToolResult == missed = {}

\* Only a running turn has steers stored that its worker has not read.
UnreadOnlyWhileRunning == log # <<>> => Running

\* The steers waiting on a record come first in the log, ahead of any entry
\* another process stored.
HeldFirst == \A i \in DOMAIN log : log[i] \in held => \A j \in 1..i : log[j] \in held

=============================================================================
