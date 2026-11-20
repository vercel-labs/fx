--------------------------- MODULE AcpTurnEvents ---------------------------
(***************************************************************************)
(* What fx acp tells one client about a running turn (src/acp/prompt.zig): *)
(* the "Turn events" section of src/protocol/spec/sh-fx.md, and ACP v1's   *)
(* compaction updates.                                                     *)
(*                                                                         *)
(* fx's agent loop reports a turn's progress (its phase, token counts and  *)
(* provider), each model call that ends, each compaction of the context,  *)
(* and the finished turn. fx writes messages to the connection in order,  *)
(* and the client reads them later (Deliver).                             *)
(*                                                                         *)
(*  - The client lists the parts it wants (Parts): "progress" is          *)
(*    sh.fx/turnProgress, "calls" sh.fx/modelCalls, "usage" sh.fx/usage,  *)
(*    and "compaction" ACP's session.compaction. fx sends a part only to a *)
(*    client that lists it, and every event of a part it lists.           *)
(*  - A compaction sends in_progress once its summary or its publication  *)
(*    starts, and one end when it settles: completed when it succeeded,   *)
(*    failed when it failed, and cancelled otherwise. One that settles    *)
(*    before either starts sends nothing, unless it failed: then failed   *)
(*    is its only update.                                                 *)
(*  - The turn's response comes after every message of the turn, and      *)
(*    carries the turn's usage when the client lists "usage".             *)
(*                                                                         *)
(* `Rules` set to FALSE gives fx acp before these rules:                  *)
(* the loop's progress, model calls, compactions, and finish              *)
(* reach fx acp's catch-all arm or no hook at all, and nothing is sent,   *)
(* so only the response reaches the client. AcpTurnEventsToday.cfg shows  *)
(* Complete failing.                                                      *)
(*                                                                         *)
(* Compactions have the ids in Ks and run one at a time, in id order, in  *)
(* any turn. A compaction's stage is "chosen" once fx-compactor picked    *)
(* what to compact, "summary" once its summary started, and "published"   *)
(* once it was being saved.                                               *)
(*                                                                         *)
(* tests/tla/drivers/acp/turn_events/driver.ts runs the real fx acp       *)
(* through turns and has TLC check each run against this model through    *)
(* AcpTurnEventsTrace.tla.                                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Rules,          \* TRUE: the turn events rules; FALSE: fx acp before them
    Parts,          \* the parts the client lists
    Ks,             \* compaction ids, 1..n
    MaxProgress,    \* progress reports per turn
    MaxCalls,       \* model calls per turn
    MaxTurns

AllParts == {"progress", "calls", "usage", "compaction"}
Outcomes == {"succeeded", "failed", "cancelled", "no_op"}
Ends == {"completed", "failed", "cancelled"}
Stages == {"none", "chosen", "summary", "published", "ended"}

ASSUME Parts \subseteq AllParts /\ Ks \subseteq Nat \ {0}

VARIABLES
    turn,       \* the number of the client's current turn, 0 before the first
    running,    \* the current turn runs
    prog,       \* progress reports the loop made in this turn
    calls,      \* model calls that ended in this turn
    finished,   \* the loop reported the finished turn
    stage,      \* [Ks -> Stages]
    outcome,    \* [Ks -> Outcomes \cup {"none"}]
    started,    \* [Ks -> BOOLEAN]: fx sent this compaction's in_progress
    chan,       \* messages fx wrote and the client hasn't read
    got,        \* what the client read in this turn
    seen,       \* [Ks -> Seq(statuses)]: compaction updates the client read
    late        \* the client read a message of a turn after its response

vars == <<turn, running, prog, calls, finished, stage, outcome, started, chan, got, seen, late>>

Listed(p) == Rules /\ p \in Parts

Msg(kind, k, status, usage) == [kind |-> kind, k |-> k, status |-> status, usage |-> usage]

WriteIf(cond, m) == chan' = IF cond THEN Append(chan, m) ELSE chan

NoGot == [progress |-> 0, calls |-> 0, response |-> FALSE, usage |-> FALSE]

Active == {k \in Ks : stage[k] \in {"chosen", "summary", "published"}}

Init ==
    /\ turn = 0
    /\ running = FALSE
    /\ prog = 0
    /\ calls = 0
    /\ finished = FALSE
    /\ stage = [k \in Ks |-> "none"]
    /\ outcome = [k \in Ks |-> "none"]
    /\ started = [k \in Ks |-> FALSE]
    /\ chan = <<>>
    /\ got = NoGot
    /\ seen = [k \in Ks |-> <<>>]
    /\ late = FALSE

\* The client sends a prompt once it has the previous turn's response.
Prompt ==
    /\ ~running /\ turn < MaxTurns
    /\ turn = 0 \/ got.response
    /\ turn' = turn + 1
    /\ running' = TRUE
    /\ prog' = 0 /\ calls' = 0 /\ finished' = FALSE
    /\ got' = NoGot
    /\ UNCHANGED <<stage, outcome, started, chan, seen, late>>

Progress ==
    /\ running /\ ~finished /\ prog < MaxProgress
    /\ prog' = prog + 1
    /\ WriteIf(Listed("progress"), Msg("progress", 0, "none", FALSE))
    /\ UNCHANGED <<turn, running, calls, finished, stage, outcome, started, got, seen, late>>

Call ==
    /\ running /\ ~finished /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ WriteIf(Listed("calls"), Msg("call", 0, "none", FALSE))
    /\ UNCHANGED <<turn, running, prog, finished, stage, outcome, started, got, seen, late>>

\* fx-compactor picks what to compact. Compactions run one at a time.
Choose(k) ==
    /\ running /\ ~finished /\ stage[k] = "none" /\ Active = {}
    /\ \A j \in Ks : j < k => stage[j] = "ended"
    /\ stage' = [stage EXCEPT ![k] = "chosen"]
    /\ UNCHANGED <<turn, running, prog, calls, finished, outcome, started, chan, got, seen, late>>

\* Its summary starts, or it is being saved: the first sends in_progress.
Advance(k, next) ==
    /\ stage[k] \in {"chosen", "summary"}
    /\ next \in {"summary", "published"}
    /\ next = "summary" => stage[k] = "chosen"
    /\ stage' = [stage EXCEPT ![k] = next]
    /\ started' = [started EXCEPT ![k] = started[k] \/ Listed("compaction")]
    /\ WriteIf(Listed("compaction") /\ ~started[k], Msg("comp", k, "in_progress", FALSE))
    /\ UNCHANGED <<turn, running, prog, calls, finished, outcome, got, seen, late>>

EndOf(o) == CASE o = "succeeded" -> "completed"
              [] o = "failed" -> "failed"
              [] OTHER -> "cancelled"

\* Only a compaction being saved can succeed, and nothing to compact is
\* found before that.
Settle(k, o) ==
    /\ stage[k] \in {"chosen", "summary", "published"}
    /\ o \in Outcomes
    /\ (o = "succeeded") = (stage[k] = "published")
    /\ o = "no_op" => stage[k] # "published"
    /\ stage' = [stage EXCEPT ![k] = "ended"]
    /\ outcome' = [outcome EXCEPT ![k] = o]
    /\ WriteIf(Listed("compaction") /\ (started[k] \/ o = "failed"), Msg("comp", k, EndOf(o), FALSE))
    /\ UNCHANGED <<turn, running, prog, calls, finished, started, got, seen, late>>

Finish ==
    /\ running /\ ~finished /\ Active = {}
    /\ finished' = TRUE
    /\ UNCHANGED <<turn, running, prog, calls, stage, outcome, started, chan, got, seen, late>>

\* fx answers the prompt once the loop has finished the turn.
Respond ==
    /\ running /\ finished
    /\ running' = FALSE
    /\ chan' = Append(chan, Msg("response", 0, "none", Listed("usage")))
    /\ UNCHANGED <<turn, prog, calls, finished, stage, outcome, started, got, seen, late>>

Deliver ==
    /\ chan # <<>>
    /\ LET m == Head(chan) IN
       /\ chan' = Tail(chan)
       /\ late' = (late \/ (got.response /\ m.kind # "response"))
       /\ got' = CASE m.kind = "progress" -> [got EXCEPT !.progress = @ + 1]
                   [] m.kind = "call" -> [got EXCEPT !.calls = @ + 1]
                   [] m.kind = "response" -> [got EXCEPT !.response = TRUE, !.usage = m.usage]
                   [] OTHER -> got
       /\ seen' = IF m.kind = "comp" THEN [seen EXCEPT ![m.k] = Append(@, m.status)] ELSE seen
    /\ UNCHANGED <<turn, running, prog, calls, finished, stage, outcome, started>>

Next ==
    \/ Prompt \/ Progress \/ Call \/ Finish \/ Respond \/ Deliver
    \/ \E k \in Ks : \/ Choose(k) \/ Advance(k, "summary") \/ Advance(k, "published")
                     \/ \E o \in Outcomes : Settle(k, o)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Statuses == Ends \cup {"in_progress"}
Message == [kind : {"progress", "call", "comp", "response"}, k : Ks \cup {0},
            status : Statuses \cup {"none"}, usage : BOOLEAN]

TypeOK ==
    /\ turn \in 0..MaxTurns /\ running \in BOOLEAN
    /\ prog \in 0..MaxProgress /\ calls \in 0..MaxCalls /\ finished \in BOOLEAN
    /\ stage \in [Ks -> Stages] /\ outcome \in [Ks -> Outcomes \cup {"none"}]
    /\ started \in [Ks -> BOOLEAN]
    /\ \A i \in 1..Len(chan) : chan[i] \in Message
    /\ got \in [progress : Nat, calls : Nat, response : BOOLEAN, usage : BOOLEAN]
    /\ \A k \in Ks : \A i \in 1..Len(seen[k]) : seen[k][i] \in Statuses
    /\ late \in BOOLEAN

PartOf(m) == CASE m.kind = "progress" -> "progress"
               [] m.kind = "call" -> "calls"
               [] m.kind = "comp" -> "compaction"
               [] OTHER -> "none"

\* A client gets only the parts it lists: a plain ACP client gets none.
OptIn ==
    /\ \A i \in 1..Len(chan) :
         /\ chan[i].kind # "response" => PartOf(chan[i]) \in Parts
         /\ chan[i].usage => "usage" \in Parts
    /\ got.progress > 0 => "progress" \in Parts
    /\ got.calls > 0 => "calls" \in Parts
    /\ got.usage => "usage" \in Parts
    /\ (\E k \in Ks : seen[k] # <<>>) => "compaction" \in Parts

\* Each compaction the client sees: an optional in_progress, then one end,
\* and nothing after it.
Lifecycle ==
    \A k \in Ks :
        \/ seen[k] = <<>>
        \/ seen[k] = <<"in_progress">>
        \/ Len(seen[k]) = 1 /\ seen[k][1] \in Ends
        \/ Len(seen[k]) = 2 /\ seen[k][1] = "in_progress" /\ seen[k][2] \in Ends

\* Once the client has the response, it has every event of the parts it
\* lists: each progress report and model call of the turn, the usage, and
\* each ended compaction exactly as it ended, and nothing for one that
\* ended before its summary or saving started without failing.
Complete ==
    got.response =>
        /\ "progress" \in Parts => got.progress = prog
        /\ "calls" \in Parts => got.calls = calls
        /\ "usage" \in Parts => got.usage
        /\ "compaction" \in Parts =>
             \A k \in Ks : stage[k] = "ended" =>
                 IF started[k] \/ outcome[k] = "failed"
                 THEN Len(seen[k]) > 0 /\ seen[k][Len(seen[k])] = EndOf(outcome[k])
                 ELSE seen[k] = <<>>

\* No message of a turn reaches the client after the turn's response.
BeforeResponse == ~late
=============================================================================
