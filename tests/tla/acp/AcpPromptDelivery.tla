------------------------- MODULE AcpPromptDelivery -------------------------
(***************************************************************************)
(* Steering and queued prompts in fx's ACP server, as the sh.fx spec's    *)
(* "Steering and queued prompts" section defines them                     *)
(* (src/protocol/spec/sh-fx.md), which fx's ACP path follows.            *)
(* `Rules` set to FALSE gives the path before it followed them, and the   *)
(* AcpPromptDeliveryToday-*.cfg configs show each rule failing there.     *)
(* tests/tla/sdk/DurableSteer.tla models the same rules for libfx's host  *)
(* steering, which the fx CLI follows.                                    *)
(*                                                                        *)
(* A client sends prompts while a turn runs, each with a delivery in      *)
(* `_meta["sh.fx/delivery"]`:                                             *)
(*                                                                        *)
(*  - A prompt that arrives while no turn runs starts one.                *)
(*  - A prompt with no delivery that arrives during a turn fails with     *)
(*    -32600.                                                             *)
(*  - A steer holds text only; one with an image fails with -32602. A     *)
(*    steer that arrives while the model streams a reply cuts the reply   *)
(*    short, and the turn takes it in its next request (X20). One that    *)
(*    arrives between requests waits, and the turn takes it at its next   *)
(*    request: after the running tool, or, when the reply has ended, by   *)
(*    going on instead of ending (X22).                                   *)
(*  - A steer that arrives after the turn's last check for steers, while  *)
(*    it finishes, waits until the turn stops taking input; it then runs  *)
(*    as the next turn (X19). Steers that arrive after that, and every    *)
(*    waiting steer when the client stops the turn, run together as the   *)
(*    next turn, before any queued prompt (Q39, Q40).                     *)
(*  - A queued prompt waits and runs as a turn of its own, in the order   *)
(*    fx received them.                                                   *)
(*  - $/cancel_request withdraws a steer or queued prompt that hasn't run *)
(*    with -32800; session/close answers each one with -32800.            *)
(*  - Each prompt gets exactly one answer: a turn's stopReason, and for a *)
(*    steer the delivery: absorbed into the running turn, or next_turn.   *)
(*                                                                        *)
(* Before (Rules = FALSE): a steer never cut a reply short; a steer that  *)
(* waited when the reply ended went on in the same turn, as under the     *)
(* rules; one that arrived while the turn finished failed with -32600; a  *)
(* stop failed the waiting steers with -32800; a late steer ran as its    *)
(* own next turn; fx listed only the steer delivery, so a queued prompt   *)
(* failed with -32602; and $/cancel_request ignored a steer.              *)
(*                                                                        *)
(* The phases of the running turn: "gen" while the model streams a reply, *)
(* "decide" once the reply has streamed and before the turn's next        *)
(* request, "tool" while a tool runs, "finishing" once the turn has found *)
(* no steer waiting at the reply's end but still takes input, and         *)
(* "closing" once it has stopped taking input.                            *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,      \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Msgs,       \* the prompts a client may send, each once
    MaxTools,   \* tool calls the model may make in the session
    MaxCancels, \* stops the client may send
    AllowClose  \* whether the client may close the session

ASSUME Rules \in BOOLEAN /\ AllowClose \in BOOLEAN
ASSUME MaxTools \in Nat /\ MaxCancels \in Nat

\* What each prompt is. P starts the session's work, M is a prompt with no
\* delivery, S1 and S2 are steers, I is a steer with an image, and Q1 and Q2
\* are queued prompts.
Kind(m) ==
    CASE m \in {"P", "M"}        -> "plain"
      [] m \in {"S1", "S2", "I"} -> "steer"
      [] m \in {"Q1", "Q2"}      -> "queue"

Range(s) == {s[k] : k \in DOMAIN s}
Remove(s, m) == SelectSeq(s, LAMBDA x : x # m)

NoAnswer == [kind |-> "none", stop |-> "", delivery |-> "", code |-> 0]
Ok(stop, delivery) == [kind |-> "ok", stop |-> stop, delivery |-> delivery, code |-> 0]
Err(code) == [kind |-> "err", stop |-> "", delivery |-> "", code |-> code]
NoTurn == [owner |-> "none", ctx |-> {}, group |-> {}]

VARIABLES
    sent,     \* the prompts fx received, in order
    running,  \* whether a turn runs
    phase,    \* the running turn's phase
    cur,      \* the running turn: who started it, what it holds, its late steers
    waiting,  \* steers the running turn may still take, in order
    late,     \* steers for the next turn, in order
    queue,    \* queued prompts, in order
    answers,  \* each prompt's answer
    placed,   \* how many turns held each prompt
    started,  \* the prompt that started each turn, in order
    tools,
    cancels,
    closed
vars == <<sent, running, phase, cur, waiting, late, queue, answers, placed, started, tools, cancels, closed>>

Init ==
    /\ sent = <<>>
    /\ running = FALSE
    /\ phase = "gen"
    /\ cur = NoTurn
    /\ waiting = <<>>
    /\ late = <<>>
    /\ queue = <<>>
    /\ answers = [m \in Msgs |-> NoAnswer]
    /\ placed = [m \in Msgs |-> 0]
    /\ started = <<>>
    /\ tools = 0
    /\ cancels = 0
    /\ closed = FALSE

Place(ms) == [m \in Msgs |-> IF m \in ms THEN placed[m] + 1 ELSE placed[m]]

\* The delivery a prompt that turn `t` held gets in its answer.
Delivery(t, m) ==
    IF m \in t.group THEN "next_turn"
    ELSE IF m = t.owner \/ Kind(m) # "steer" THEN "none"
    ELSE "absorbed"

AnswerTurn(t, stop) ==
    [m \in Msgs |-> IF m \in t.ctx THEN Ok(stop, Delivery(t, m)) ELSE answers[m]]

\* After a turn ends: the late steers run next, together (today, the first
\* runs alone), then the queued prompts, one turn each.
StartNext ==
    CASE late # <<>> ->
             LET group == IF Rules THEN Range(late) ELSE {Head(late)} IN
             /\ running' = TRUE
             /\ phase' = "gen"
             /\ cur' = [owner |-> Head(late), ctx |-> group, group |-> group]
             /\ late' = IF Rules THEN <<>> ELSE Tail(late)
             /\ placed' = Place(group)
             /\ started' = Append(started, Head(late))
             /\ UNCHANGED queue
      [] queue # <<>> ->
             /\ running' = TRUE
             /\ phase' = "gen"
             /\ cur' = [owner |-> Head(queue), ctx |-> {Head(queue)}, group |-> {}]
             /\ queue' = Tail(queue)
             /\ placed' = Place({Head(queue)})
             /\ started' = Append(started, Head(queue))
             /\ UNCHANGED late
      [] OTHER ->
             /\ running' = FALSE
             /\ cur' = NoTurn
             /\ UNCHANGED <<phase, late, queue, placed, started>>

Send(m) ==
    /\ ~closed
    /\ m \notin Range(sent)
    /\ sent' = Append(sent, m)
    /\ UNCHANGED <<tools, cancels, closed>>
    /\ IF ~running
       THEN \* Any prompt starts a turn when none runs.
            /\ running' = TRUE
            /\ phase' = "gen"
            /\ cur' = [owner |-> m, ctx |-> {m}, group |-> {}]
            /\ placed' = Place({m})
            /\ started' = Append(started, m)
            /\ UNCHANGED <<waiting, late, queue, answers>>
       ELSE CASE Kind(m) = "plain" ->
                     /\ answers' = [answers EXCEPT ![m] = Err(-32600)]
                     /\ UNCHANGED <<running, phase, cur, waiting, late, queue, placed, started>>
              [] m = "I" ->
                     /\ answers' = [answers EXCEPT ![m] = Err(-32602)]
                     /\ UNCHANGED <<running, phase, cur, waiting, late, queue, placed, started>>
              [] Kind(m) = "steer" /\ phase = "closing" ->
                     /\ late' = Append(late, m)
                     /\ UNCHANGED <<running, phase, cur, waiting, queue, answers, placed, started>>
              [] Kind(m) = "steer" /\ phase = "gen" /\ Rules ->
                     \* The reply is cut short; the turn's next request holds the steer.
                     /\ cur' = [cur EXCEPT !.ctx = @ \cup {m}]
                     /\ placed' = Place({m})
                     /\ UNCHANGED <<running, phase, waiting, late, queue, answers, started>>
              [] Kind(m) = "steer" ->
                     /\ waiting' = Append(waiting, m)
                     /\ UNCHANGED <<running, phase, cur, late, queue, answers, placed, started>>
              [] Kind(m) = "queue" /\ Rules ->
                     /\ queue' = Append(queue, m)
                     /\ UNCHANGED <<running, phase, cur, waiting, late, answers, placed, started>>
              [] OTHER ->
                     \* Before the rules, fx listed only the steer delivery and refused a queued one.
                     /\ answers' = [answers EXCEPT ![m] = Err(-32602)]
                     /\ UNCHANGED <<running, phase, cur, waiting, late, queue, placed, started>>

\* The model finishes streaming a reply.
StreamEnd ==
    /\ running /\ phase = "gen"
    /\ phase' = "decide"
    /\ UNCHANGED <<sent, running, cur, waiting, late, queue, answers, placed, started, tools, cancels, closed>>

\* The reply asks for a tool, which runs.
ToolCall ==
    /\ running /\ phase = "decide" /\ tools < MaxTools
    /\ phase' = "tool"
    /\ tools' = tools + 1
    /\ UNCHANGED <<sent, running, cur, waiting, late, queue, answers, placed, started, cancels, closed>>

\* The tool ends; the turn's next request holds the waiting steers.
ToolEnd ==
    /\ running /\ phase = "tool"
    /\ phase' = "gen"
    /\ cur' = [cur EXCEPT !.ctx = @ \cup Range(waiting)]
    /\ placed' = Place(Range(waiting))
    /\ waiting' = <<>>
    /\ UNCHANGED <<sent, running, late, queue, answers, started, tools, cancels, closed>>

\* The reply asks for nothing more. With steers waiting, the turn goes on and
\* takes them (X22), today too. Otherwise the turn finishes.
ReplyEnd ==
    /\ running /\ phase = "decide"
    /\ IF waiting # <<>>
       THEN /\ phase' = "gen"
            /\ cur' = [cur EXCEPT !.ctx = @ \cup Range(waiting)]
            /\ placed' = Place(Range(waiting))
            /\ waiting' = <<>>
       ELSE /\ phase' = "finishing"
            /\ UNCHANGED <<cur, placed, waiting>>
    /\ UNCHANGED <<sent, running, late, queue, answers, started, tools, cancels, closed>>

\* The finishing turn stops taking input. A steer that arrived while it
\* finished runs as the next turn (X19); today it fails with -32600.
StopInput ==
    /\ running /\ phase = "finishing"
    /\ phase' = "closing"
    /\ waiting' = <<>>
    /\ IF Rules
       THEN /\ late' = late \o waiting
            /\ UNCHANGED answers
       ELSE /\ answers' = [m \in Msgs |-> IF m \in Range(waiting) THEN Err(-32600) ELSE answers[m]]
            /\ UNCHANGED late
    /\ UNCHANGED <<sent, running, cur, queue, placed, started, tools, cancels, closed>>

\* The turn that stopped taking input answers, and the next one starts.
Finish ==
    /\ running /\ phase = "closing"
    /\ answers' = AnswerTurn(cur, "end_turn")
    /\ StartNext
    /\ UNCHANGED <<sent, waiting, tools, cancels, closed>>

\* session/cancel stops the running turn. Under the rules its waiting steers
\* run next with the late ones (Q39, Q40); today they fail with -32800.
Cancel ==
    /\ running /\ phase # "closing" /\ cancels < MaxCancels
    /\ cancels' = cancels + 1
    /\ waiting' = <<>>
    /\ UNCHANGED <<sent, tools, closed>>
    /\ IF Rules
       THEN LET handed == late \o waiting IN
            /\ answers' = AnswerTurn(cur, "cancelled")
            /\ CASE handed # <<>> ->
                        /\ running' = TRUE
                        /\ phase' = "gen"
                        /\ cur' = [owner |-> Head(handed), ctx |-> Range(handed), group |-> Range(handed)]
                        /\ late' = <<>>
                        /\ placed' = Place(Range(handed))
                        /\ started' = Append(started, Head(handed))
                        /\ UNCHANGED queue
                 [] queue # <<>> ->
                        /\ running' = TRUE
                        /\ phase' = "gen"
                        /\ cur' = [owner |-> Head(queue), ctx |-> {Head(queue)}, group |-> {}]
                        /\ queue' = Tail(queue)
                        /\ placed' = Place({Head(queue)})
                        /\ started' = Append(started, Head(queue))
                        /\ UNCHANGED late
                 [] OTHER ->
                        /\ running' = FALSE
                        /\ cur' = NoTurn
                        /\ UNCHANGED <<phase, late, queue, placed, started>>
       ELSE /\ answers' = [m \in Msgs |->
                    IF m \in cur.ctx THEN Ok("cancelled", Delivery(cur, m))
                    ELSE IF m \in Range(waiting) THEN Err(-32800)
                    ELSE answers[m]]
            /\ StartNext

\* $/cancel_request withdraws a steer or queued prompt that hasn't run.
Withdraw(m) ==
    /\ Rules
    /\ m \in Range(waiting) \cup Range(late) \cup Range(queue)
    /\ answers' = [answers EXCEPT ![m] = Err(-32800)]
    /\ waiting' = Remove(waiting, m)
    /\ late' = Remove(late, m)
    /\ queue' = Remove(queue, m)
    /\ UNCHANGED <<sent, running, phase, cur, placed, started, tools, cancels, closed>>

\* session/close stops the running turn and answers what hasn't run with -32800.
Close ==
    /\ AllowClose /\ Rules /\ ~closed
    /\ closed' = TRUE
    /\ answers' = [m \in Msgs |->
            IF running /\ m \in cur.ctx THEN Ok("cancelled", Delivery(cur, m))
            ELSE IF m \in Range(waiting) \cup Range(late) \cup Range(queue) THEN Err(-32800)
            ELSE answers[m]]
    /\ running' = FALSE
    /\ cur' = NoTurn
    /\ waiting' = <<>>
    /\ late' = <<>>
    /\ queue' = <<>>
    /\ UNCHANGED <<sent, phase, placed, started, tools, cancels>>

Next ==
    \/ \E m \in Msgs : Send(m) \/ Withdraw(m)
    \/ StreamEnd \/ ToolCall \/ ToolEnd \/ ReplyEnd \/ StopInput \/ Finish \/ Cancel \/ Close

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ running \in BOOLEAN
    /\ phase \in {"gen", "decide", "tool", "finishing", "closing"}
    /\ Range(waiting) \cup Range(late) \cup Range(queue) \subseteq Range(sent)
    /\ \A m \in Msgs : answers[m].kind \in {"none", "ok", "err"}

\* No prompt is placed in two turns.
AtMostOnce == \A m \in Msgs : placed[m] <= 1

\* A prompt's answer, once given, never changes.
AnsweredOnce == [][\A m \in Msgs : answers[m].kind # "none" => answers'[m] = answers[m]]_vars

\* While the model streams a reply, no steer waits: it cut the reply short (X20).
NoSteerWaitsOnReply == (running /\ phase = "gen") => waiting = <<>>

\* A reply never ends a turn while steers wait (X22).
ReplyEndContinues == [][(running /\ phase = "decide" /\ phase' = "finishing") => waiting = <<>>]_vars

\* When nothing is pending, every prompt fx received has its answer, and no
\* steer or queued prompt failed except by being withdrawn or closed.
Quiescent == ~running /\ waiting = <<>> /\ late = <<>> /\ queue = <<>>
NothingLost ==
    Quiescent =>
        \A m \in Range(sent) :
            /\ answers[m].kind # "none"
            /\ (Kind(m) \in {"steer", "queue"} /\ m # "I" /\ answers[m].kind = "err") => answers[m].code = -32800

\* A steer's delivery is where it ran; no steer is dropped (Q39).
DeliveryValues == \A m \in Msgs : answers[m].delivery \in {"", "none", "absorbed", "next_turn"}

\* A stop fails no prompt: the steers it finds waiting run next (Q39).
StopKeepsSteers ==
    [][cancels' > cancels => \A m \in Msgs : answers[m].kind = "none" => answers'[m].kind # "err"]_vars

\* Queued prompts start their turns in the order fx received them.
SentIndex(m) == CHOOSE k \in DOMAIN sent : sent[k] = m
QueuedInOrder ==
    \A i, j \in DOMAIN started :
        (i < j /\ Kind(started[i]) = "queue" /\ Kind(started[j]) = "queue") =>
            SentIndex(started[i]) < SentIndex(started[j])

\* When a turn starts while late steers wait, it starts with all of them (Q40),
\* before any queued prompt.
LateRunTogether ==
    [][(Len(started') > Len(started) /\ late # <<>>) =>
           /\ late' = <<>>
           /\ started'[Len(started')] \in Range(late)]_vars

\* A steer with an image, sent during a turn, fails with -32602.
ImageSteerRefused ==
    [][(running /\ "I" \in Msgs /\ "I" \notin Range(sent) /\ "I" \in Range(sent')) =>
           answers'["I"] = Err(-32602)]_vars
=============================================================================
