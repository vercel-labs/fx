---------------------------- MODULE StopMessage ----------------------------
(***************************************************************************)
(* Main's stop and its next messages to a subagent: Runtime.stopChild and  *)
(* the message path in src/core/subagent/tool_host.zig, Owner.stop and     *)
(* Owner.steer in src/core/subagent/managed_owner.zig, and the subagent    *)
(* group in src/core/agent/runtime/parallel_execution.zig.                 *)
(*                                                                         *)
(* A stop answers at once and the stopped turn ends a little later: the    *)
(* subagent is "ending" in between. A new turn is "starting" until its     *)
(* worker begins (Owner.steer answers .starting). A message to a subagent  *)
(* that is                                                                 *)
(*   absent   (never started, or closed) starts one, and its turn reads it;*)
(*   idle     starts a turn, and the turn reads it;                       *)
(*   starting waits until the turn begins, then joins it: the message     *)
(*            path holds main's call (calls to other subagents still run). *)
(*            fx gives up after a wait limit that only a stuck start      *)
(*            reaches, which the model leaves out;                         *)
(*   running  joins the running turn, unread until the turn reads it;     *)
(*   ending   waits, and the next turn takes it with every other waiting  *)
(*            message as soon as the stopped turn has ended;               *)
(*   closing  is refused, and main hears it: a close is under way, and a  *)
(*            message after the closed work ends starts a new subagent.   *)
(* A stop drops main's messages the stopped turn has not read and the      *)
(* waiting ones, and its answer counts both, so main hears of every        *)
(* message it loses. A user's stop on the subagent's screen ends the turn  *)
(* the same way and tells main the same count. A stopped turn reads no     *)
(* more messages. A close drops and counts the same; a working subagent   *)
(* is "closing" until its work ends; then no subagent has the name, a stop *)
(* or close of it is unavailable, and a message starts a new one.          *)
(*                                                                         *)
(* Main writes a step of one or two calls. Calls to one subagent run in    *)
(* the order written; calls to different subagents may run in any order.  *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before this design: a message to a work its parent        *)
(* stopped is refused, one to a work the user stopped joins it and is lost *)
(* with it, a step's subagent calls run in any order, and a parent's stop  *)
(* counts only the waiting messages, and a message to a starting turn     *)
(* waits for the turn after it.                                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Subs, MsgsPer, MaxSteps, MaxStops, Bug

Bugs == {"none", "today", "refuse_ending", "no_order", "uncounted",
         "join_user_ending", "read_after_stop", "drop_waiting_at_end",
         "queue_closing", "start_next_turn"}
ASSUME Bug \in Bugs

Msgs == Subs \X (1..MsgsPer)
NoMsg == <<"none", 0>>
SubOf(m) == m[1]
Phases == {"absent", "idle", "starting", "running", "ending_parent", "ending_user", "closing"}
Endings == {"ending_parent", "ending_user"}
Answers == {"none", "started", "joined", "waits", "refused"}
Ops == {"none", "step", "send", "stop", "close", "user_stop", "read",
        "finish", "end", "begin"}

Range(sq) == {sq[k] : k \in DOMAIN sq}
RemoveAt(sq, i) == [k \in 1..(Len(sq) - 1) |-> IF k < i THEN sq[k] ELSE sq[k + 1]]

Call(op, s, m, id) == [op |-> op, sub |-> s, msg |-> m, id |-> id]
Event(op, s, m, answer, count) ==
    [op |-> op, sub |-> s, msg |-> m, answer |-> answer, count |-> count]
None == Event("none", "none", NoMsg, "none", 0)

VARIABLES
    phase,        \* [Subs -> Phases]
    unread,       \* [Subs -> SUBSET Msgs]: joined the running turn, not read
    waitq,        \* [Subs -> Seq(Msgs)]: waiting for the next turn
    read,         \* messages a turn read
    dropped,      \* messages thrown away
    toldDropped,  \* messages a stop's, a user stop's, or a close's count included
    told,         \* [Msgs -> Answers]: what main heard when it sent each one
    sent,         \* messages main has written into a step
    stops,        \* stops, user stops, and closes so far
    steps,        \* steps main has written
    step,         \* the current step's calls not yet run
    covered,      \* <<m, id>>: m was written after stop call id to its subagent
    refusedOpen,  \* messages refused although their subagent was not closing
    coverBroken,  \* a stop dropped a message written after it in its step
    lateStart,    \* messages sent to a starting turn that fx held for a later one
    last          \* the last action, which a trace of fx matches

vars == <<phase, unread, waitq, read, dropped, toldDropped, told, sent,
          stops, steps, step, covered, refusedOpen, coverBroken, lateStart, last>>

Init ==
    /\ phase = [s \in Subs |-> "absent"]
    /\ unread = [s \in Subs |-> {}]
    /\ waitq = [s \in Subs |-> <<>>]
    /\ read = {}
    /\ dropped = {}
    /\ toldDropped = {}
    /\ told = [m \in Msgs |-> "none"]
    /\ sent = {}
    /\ stops = 0
    /\ steps = 0
    /\ step = <<>>
    /\ covered = {}
    /\ refusedOpen = {}
    /\ coverBroken = FALSE
    /\ lateStart = {}
    /\ last = None

-----------------------------------------------------------------------------
(* Main writes its next step once the last one has run.                    *)

Choices ==
    {Call("send", SubOf(m), m, <<0, 0>>) : m \in Msgs \ sent}
    \cup {Call(op, s, NoMsg, <<0, 0>>) : op \in {"stop", "close"}, s \in Subs}

Ided(calls) ==
    [k \in 1..Len(calls) |->
        Call(calls[k].op, calls[k].sub, calls[k].msg, <<steps + 1, k>>)]

Write(calls) ==
    LET n == Len(calls)
        sends == {k \in 1..n : calls[k].op = "send"}
        others == n - Cardinality(sends)
        ided == Ided(calls)
    IN /\ stops + others <= MaxStops
       /\ Cardinality({calls[k].msg : k \in sends}) = Cardinality(sends)
       /\ step' = ided
       /\ sent' = sent \cup {calls[k].msg : k \in sends}
       /\ covered' = covered \cup
            {<<ided[pair[1]].msg, ided[pair[2]].id>> :
                pair \in {q \in sends \X (1..n) :
                    q[2] < q[1] /\ ided[q[2]].op = "stop" /\ ided[q[2]].sub = ided[q[1]].sub}}
       /\ steps' = steps + 1
       /\ stops' = stops + others
       /\ last' = Event("step", "none", NoMsg, "none", n)

NewStep ==
    /\ step = <<>>
    /\ steps < MaxSteps
    /\ \/ \E c \in Choices : Write(<<c>>)
       \/ \E c1, c2 \in Choices : c1 # c2 /\ Write(<<c1, c2>>)
    /\ UNCHANGED <<phase, unread, waitq, read, dropped, toldDropped, told,
                   refusedOpen, coverBroken, lateStart>>

-----------------------------------------------------------------------------
(* One call of the step runs. Calls to one subagent wait for the earlier   *)
(* ones to it.                                                             *)

Ready(i) ==
    \/ Bug \in {"today", "no_order"}
    \/ \A j \in 1..(i - 1) : step[j].sub # step[i].sub

RefusesEnding(s) ==
    phase[s] = "ending_parent" /\ Bug \in {"today", "refuse_ending"}

JoinsEnding(s) ==
    phase[s] = "ending_user" /\ Bug \in {"today", "join_user_ending"}

\* fx before the start wait: a message to a starting turn waits for the next.
StartNextTurn(s) ==
    phase[s] = "starting" /\ Bug \in {"today", "start_next_turn"}

\* A call that waits for its subagent's turn to begin can't run yet.
SendRuns(c) == phase[c.sub] # "starting" \/ StartNextTurn(c.sub)

DoSend(c) ==
    LET s == c.sub
        m == c.msg
    IN
    \/ /\ phase[s] \in {"absent", "idle"}
       /\ phase' = [phase EXCEPT ![s] = "starting"]
       /\ read' = read \cup {m}
       /\ told' = [told EXCEPT ![m] = "started"]
       /\ last' = Event("send", s, m, "started", 0)
       /\ UNCHANGED <<unread, waitq, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
    \/ /\ StartNextTurn(s)
       /\ waitq' = [waitq EXCEPT ![s] = Append(@, m)]
       /\ told' = [told EXCEPT ![m] = "waits"]
       /\ lateStart' = lateStart \cup {m}
       /\ last' = Event("send", s, m, "waits", 0)
       /\ UNCHANGED <<phase, read, unread, dropped, toldDropped, refusedOpen, coverBroken, stops>>
    \/ /\ \/ phase[s] = "running"
          \/ JoinsEnding(s)
       /\ unread' = [unread EXCEPT ![s] = @ \cup {m}]
       /\ told' = [told EXCEPT ![m] = "joined"]
       /\ last' = Event("send", s, m, "joined", 0)
       /\ UNCHANGED <<phase, read, waitq, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
    \/ /\ RefusesEnding(s)
       /\ told' = [told EXCEPT ![m] = "refused"]
       /\ refusedOpen' = refusedOpen \cup {m}
       /\ last' = Event("send", s, m, "refused", 0)
       /\ UNCHANGED <<phase, read, unread, waitq, dropped, toldDropped, coverBroken, stops, lateStart>>
    \/ /\ phase[s] \in Endings
       /\ ~RefusesEnding(s)
       /\ ~JoinsEnding(s)
       /\ waitq' = [waitq EXCEPT ![s] = Append(@, m)]
       /\ told' = [told EXCEPT ![m] = "waits"]
       /\ last' = Event("send", s, m, "waits", 0)
       /\ UNCHANGED <<phase, read, unread, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
    \/ /\ phase[s] = "closing"
       /\ Bug = "queue_closing"
       /\ waitq' = [waitq EXCEPT ![s] = Append(@, m)]
       /\ told' = [told EXCEPT ![m] = "waits"]
       /\ last' = Event("send", s, m, "waits", 0)
       /\ UNCHANGED <<phase, read, unread, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
    \/ /\ phase[s] = "closing"
       /\ Bug # "queue_closing"
       /\ told' = [told EXCEPT ![m] = "refused"]
       /\ last' = Event("send", s, m, "refused", 0)
       /\ UNCHANGED <<phase, read, unread, waitq, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>

\* A stop drops the waiting messages now, and the stopped turn's unread ones
\* when it ends; its answer counts both.
DoStop(c) ==
    LET s == c.sub
        waiting == Range(waitq[s])
        counted == waiting \cup
            (IF phase[s] = "running" /\ Bug \notin {"today", "uncounted"}
             THEN unread[s] ELSE {})
    IN
    \* The close already ended the turn and dropped what waited: fx answers
    \* as for a second stop, and drops nothing more.
    \/ /\ phase[s] = "closing"
       /\ last' = Event("stop", s, NoMsg, "stopped", 0)
       /\ UNCHANGED <<phase, waitq, dropped, toldDropped, coverBroken>>
    \/ /\ phase[s] = "absent"
       /\ last' = Event("stop", s, NoMsg, "unavailable", 0)
       /\ UNCHANGED <<phase, waitq, dropped, toldDropped, coverBroken>>
    \/ /\ phase[s] \notin {"closing", "absent"}
       /\ phase' = [phase EXCEPT ![s] = IF @ \in {"starting", "running"} THEN "ending_parent" ELSE @]
       /\ waitq' = [waitq EXCEPT ![s] = <<>>]
       /\ dropped' = dropped \cup waiting
       /\ toldDropped' = toldDropped \cup counted
       /\ coverBroken' = (coverBroken \/
            \E m \in waiting \cup unread[s] : <<m, c.id>> \in covered)
       \* A work that is still ending still counts as stopped.
       /\ last' = Event("stop", s, NoMsg,
                        IF phase[s] \in {"starting", "running"} \cup Endings THEN "stopped" ELSE "idle",
                        Cardinality(counted))

DoClose(c) ==
    LET s == c.sub
        lost == Range(waitq[s]) \cup unread[s]
        \* A turn a stop already ended had its unread messages counted by
        \* that stop; the close counts each message once, as a second stop
        \* does.
        counted == Range(waitq[s]) \cup (IF phase[s] = "running" THEN unread[s] ELSE {})
    IN \/ /\ phase[s] = "absent"
          /\ last' = Event("close", s, NoMsg, "unavailable", 0)
          /\ UNCHANGED <<phase, waitq, unread, dropped, toldDropped>>
       \* A second close while the first is ending: fx answers closed and
       \* drops nothing more (`closeChild` in tool_host.zig).
       \/ /\ phase[s] = "closing"
          /\ last' = Event("close", s, NoMsg, "closed", 0)
          /\ UNCHANGED <<phase, waitq, unread, dropped, toldDropped>>
       \/ /\ phase[s] \notin {"closing", "absent"}
          /\ phase' = [phase EXCEPT ![s] = IF @ = "idle" THEN "absent" ELSE "closing"]
          /\ waitq' = [waitq EXCEPT ![s] = <<>>]
          /\ unread' = [unread EXCEPT ![s] = {}]
          /\ dropped' = dropped \cup lost
          /\ toldDropped' = toldDropped \cup counted
          /\ last' = Event("close", s, NoMsg, "closed", Cardinality(counted))

Exec ==
    \E i \in 1..Len(step) :
        /\ Ready(i)
        /\ step[i].op = "send" => SendRuns(step[i])
        /\ step' = RemoveAt(step, i)
        /\ CASE step[i].op = "send" -> DoSend(step[i])
             [] step[i].op = "stop" ->
                    DoStop(step[i]) /\ UNCHANGED <<unread, read, told, refusedOpen, stops, lateStart>>
             [] step[i].op = "close" ->
                    DoClose(step[i]) /\ UNCHANGED <<read, told, refusedOpen, coverBroken, stops, lateStart>>
        /\ UNCHANGED <<sent, steps, covered>>

-----------------------------------------------------------------------------
(* What the subagent and the user do on their own.                          *)

\* The user stops the subagent's turn on its screen; fx drops main's
\* messages in its queue and tells main how many (noteUserStop).
UserStop(s) ==
    /\ phase[s] = "running"
    /\ stops < MaxStops
    /\ phase' = [phase EXCEPT ![s] = "ending_user"]
    /\ waitq' = [waitq EXCEPT ![s] = <<>>]
    /\ dropped' = dropped \cup Range(waitq[s])
    /\ toldDropped' = toldDropped \cup Range(waitq[s]) \cup unread[s]
    /\ stops' = stops + 1
    /\ last' = Event("user_stop", s, NoMsg, "stopped",
                     Cardinality(Range(waitq[s]) \cup unread[s]))
    /\ UNCHANGED <<unread, read, told, sent, steps, step, covered, refusedOpen, coverBroken, lateStart>>

\* A starting turn's worker begins: it takes messages from now on.
Begin(s) ==
    /\ phase[s] = "starting"
    /\ phase' = [phase EXCEPT ![s] = "running"]
    /\ last' = Event("begin", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, waitq, read, dropped, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>

\* The running turn reads what joined it. A stopped turn reads nothing more.
Read(s) ==
    /\ \/ phase[s] = "running"
       \/ phase[s] \in Endings /\ Bug = "read_after_stop"
    /\ unread[s] # {}
    /\ read' = read \cup unread[s]
    /\ unread' = [unread EXCEPT ![s] = {}]
    /\ last' = Event("read", s, NoMsg, "none", Cardinality(unread[s]))
    /\ UNCHANGED <<phase, waitq, dropped, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>

\* The running turn ends on its own; waiting messages start the next one.
Finish(s) ==
    /\ phase[s] = "running"
    /\ unread[s] = {}
    /\ IF waitq[s] = <<>>
       THEN /\ phase' = [phase EXCEPT ![s] = "idle"]
            /\ UNCHANGED <<read, waitq>>
       ELSE /\ read' = read \cup Range(waitq[s])
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = "starting"]
    /\ last' = Event("finish", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, dropped, toldDropped, told, sent, stops, steps, step,
                   covered, refusedOpen, coverBroken, lateStart>>

\* The stopped turn ends: its unread messages go, and the waiting ones start
\* the next turn. A closed subagent's work ends, and a new one may take the
\* name.
EndStopped(s) ==
    /\ phase[s] \in Endings \cup {"closing"}
    /\ unread' = [unread EXCEPT ![s] = {}]
    /\ IF Bug = "drop_waiting_at_end"
       THEN /\ dropped' = dropped \cup unread[s] \cup Range(waitq[s])
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = "idle"]
            /\ UNCHANGED read
       ELSE IF phase[s] = "closing"
       THEN /\ dropped' = dropped \cup unread[s] \cup Range(waitq[s])
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = "absent"]
            /\ UNCHANGED read
       ELSE /\ dropped' = dropped \cup unread[s]
            /\ IF waitq[s] = <<>>
               THEN /\ phase' = [phase EXCEPT ![s] = "idle"]
                    /\ UNCHANGED <<read, waitq>>
               ELSE /\ read' = read \cup Range(waitq[s])
                    /\ waitq' = [waitq EXCEPT ![s] = <<>>]
                    /\ phase' = [phase EXCEPT ![s] = "starting"]
    /\ last' = Event("end", s, NoMsg, "none", Cardinality(Range(waitq[s])))
    /\ UNCHANGED <<toldDropped, told, sent, stops, steps, step, covered,
                   refusedOpen, coverBroken, lateStart>>

Next ==
    \/ NewStep
    \/ Exec
    \/ \E s \in Subs : UserStop(s) \/ Begin(s) \/ Read(s) \/ Finish(s) \/ EndStopped(s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules.                                                               *)

TypeOK ==
    /\ phase \in [Subs -> Phases]
    /\ unread \in [Subs -> SUBSET Msgs]
    /\ \A s \in Subs : Range(waitq[s]) \subseteq Msgs
    /\ read \subseteq Msgs
    /\ dropped \subseteq Msgs
    /\ toldDropped \subseteq Msgs
    /\ told \in [Msgs -> Answers]
    /\ sent \subseteq Msgs
    /\ refusedOpen \subseteq Msgs
    /\ coverBroken \in BOOLEAN
    /\ lateStart \subseteq Msgs
    /\ last.op \in Ops

\* Main hears of every message fx throws away.
NoSilentLoss == dropped \subseteq toldDropped

\* A count never includes a message the subagent read.
CountedNeverRead == toldDropped \cap read = {}

\* A message is refused only while its subagent is being closed.
RefusedOnlyWhenClosing == refusedOpen = {}

\* A stop never drops a message main wrote after it in the same step.
StopRunsFirst == ~coverBroken

\* A message main sends to a turn that is still starting joins that turn:
\* fx never holds it for a later one (Owner.steer's .starting).
JoinsStartingWork == lateStart = {}

\* Once main's steps have run and no subagent works, each message main
\* sent was read, counted as dropped, or refused while a close was under way.
Accounted ==
    (step = <<>> /\ \A s \in Subs : phase[s] \in {"absent", "idle"}) =>
        \A m \in sent : m \in read \cup toldDropped \/ told[m] = "refused"
=============================================================================
