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
(*   gap      is a subagent whose work has ended while its slot has not   *)
(*            gone on: the host has chosen the slot's next work (gap_next *)
(*            when a message waited) or none (gap_idle), but the slot has *)
(*            not yet started that work or published its end              *)
(*            (publish_test_controls.zig holds it there). A stop or close *)
(*            in the gap sees the work as ended: with none next, a stop   *)
(*            finds the subagent not working and a close closes it as an  *)
(*            idle one; with a next work chosen, they act on that work,   *)
(*            which then starts stopped, so no turn runs after a stop or  *)
(*            close and no stop is lost (Owner.markNext, Owner.stop and   *)
(*            Owner.closeByUser). A call that sends a message waits for   *)
(*            the gap to pass, as one to a starting turn waits.           *)
(*   closing  is refused, and main hears it: a close is under way, and a  *)
(*            message after the closed work ends starts a new subagent.   *)
(*   writing  is refused too: the closed work has ended and its close is  *)
(*            not written yet. Runtime.settleClose keeps the subagent     *)
(*            closing until the write returns, so every observer, the     *)
(*            list, the trace and message admission, sees it closing      *)
(*            until it is absent.                                         *)
(* A stop drops main's messages the stopped turn has not read and the      *)
(* waiting ones, and its answer counts both, so main hears of every        *)
(* message it loses. A user's stop on the subagent's screen ends the turn  *)
(* the same way and tells main the same count. A stopped turn reads no     *)
(* more messages. A close drops and counts the same; a working subagent   *)
(* is "closing" until its work ends and "writing" until its close is       *)
(* written; then no subagent has the name, a stop or close of it is        *)
(* unavailable, and a message starts a new one.                            *)
(*                                                                         *)
(* Main writes a step of one or two calls. Calls to one subagent run in    *)
(* the order written; calls to different subagents may run in any order.  *)
(*                                                                         *)
(* So that main gives related work to a subagent that has its context     *)
(* rather than starting a new one: a message that starts a new subagent   *)
(* names the subagents that are idle, and the report of a finished turn   *)
(* says its subagent is idle (the `next` field) when nothing waits to     *)
(* start its next turn. fx decides the note when the work ends, before    *)
(* the waiting messages start that turn (deliverEnd, then                 *)
(* nextOrIdleLocked in tool_host.zig). A turn that ends on its own, or    *)
(* that the user stopped, owes main a report; a turn main stopped or      *)
(* closed owes none.                                                       *)
(*                                                                         *)
(* A work's end is recorded first and the host's end hook runs after it    *)
(* (`workEnded`). A turn that ends without reading what joined it, as a    *)
(* failed or cancelled request ends it (`Fail`), leaves those messages     *)
(* with its slot (`keepLeftovers`): the subagent is "ended" until the hook *)
(* queues them ahead of the waiting ones as its next work (`Hook`,         *)
(* `handOverLeftovers` in managed_owner.zig). A stop or close of main's    *)
(* that lands then counts and drops them, and the hook queues none; a      *)
(* message main sends after that stop waits for the next work, as after    *)
(* any stop. The work the host chooses carries its messages, unread until  *)
(* its turn begins (`startq`, `Owner.markNext` and `unstarted`): a stop or *)
(* close of main's in the gap before the turn drops and counts them as     *)
(* well. The user's Esc counts none of this: it ends no work and cancels   *)
(* none (`Owner.noteUserStop`). "leftover_gap" is fx before this: a stop   *)
(* of an ended turn reached nothing, and the hook queued the kept          *)
(* messages. "leftover_uncounted" drops them without counting,             *)
(* "close_leaves_kept" leaves them with the closing subagent, and          *)
(* "gap_uncounted" is a stop or close of the chosen work that counts none  *)
(* of its messages. A chosen work can also fail before its turn begins, as *)
(* a failed bind to its agent does (`FailStart`): its failed report tells  *)
(* main its messages never ran, and the slot's count of them ends with it  *)
(* (`unstarted` is zeroed where the end is recorded), so a stop or close   *)
(* after it counts none of them twice. "stale_unstarted" is the count that *)
(* outlives that work.                                                     *)
(*                                                                          *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before this design: a message to a work its parent        *)
(* stopped is refused, one to a work the user stopped joins it and is lost *)
(* with it, a step's subagent calls run in any order, and a parent's stop  *)
(* counts only the waiting messages, and a message to a starting turn     *)
(* waits for the turn after it. "before_idle" is fx before the idle note:  *)
(* no report says its subagent is idle and no start names any.             *)
(* "gap_blind" is fx with the gap: a stop or close in it answers as for a    *)
(* running turn but acts on nothing, so the next turn runs on.             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Subs, MsgsPer, MaxSteps, MaxStops, Bug

Bugs == {"none", "today", "refuse_ending", "no_order", "uncounted",
         "join_user_ending", "read_after_stop", "drop_waiting_at_end",
         "queue_closing", "unmark_early", "start_next_turn",
         "before_idle", "note_after_take", "names_busy", "gap_blind"}
\* The defects of the kept and carried messages, beside `Bugs`.
KeptBugs == {"leftover_gap", "leftover_uncounted", "close_leaves_kept",
             "gap_uncounted", "stale_unstarted"}
ASSUME Bug \in Bugs \cup KeptBugs

\* What an end tells main: no report, a report that says its subagent is
\* idle, or a plain report.
Notes == {"none", "idle", "plain"}

Msgs == Subs \X (1..MsgsPer)
NoMsg == <<"none", 0>>
SubOf(m) == m[1]
Phases == {"absent", "idle", "starting", "running", "ending_parent", "ending_user", "closing", "writing",
           "gap_idle", "gap_next"}
Gaps == {"gap_idle", "gap_next"}
Endings == {"ending_parent", "ending_user"}
Answers == {"none", "started", "joined", "waits", "refused"}
Ops == {"none", "step", "send", "stop", "close", "user_stop", "read",
        "finish", "end", "begin", "write_close", "publish"}

\* The phases and ops of the kept messages, beside `Phases` and `Ops`.
AllPhases == Phases \cup {"ended"}
AllOps == Ops \cup {"fail", "hook", "fail_start"}

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
    startq,       \* [Subs -> SUBSET Msgs]: the chosen next work's own messages, unread until its turn begins
    kept,         \* [Subs -> SUBSET Msgs]: unread by a turn that ended, kept by its slot for the end hook
    read,         \* messages a turn read
    dropped,      \* messages thrown away
    stoppedQ,     \* messages queued, kept or unread when a stop or close of their subagent answered
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
    last,         \* the last action, which a trace of fx matches
    note,         \* what the last end told main (Notes)
    named,        \* the subagents the last message named as idle
    noteWrong,    \* an end's report said idle when its subagent was not, or the reverse
    namedWrong    \* a new subagent's start named other than the idle subagents

idleVars == <<note, named, noteWrong, namedWrong>>

\* What most actions leave alone.
heldVars == <<startq, stoppedQ, kept>>

vars == <<phase, unread, waitq, startq, kept, read, dropped, stoppedQ, toldDropped, told, sent,
          stops, steps, step, covered, refusedOpen, coverBroken, lateStart, last,
          note, named, noteWrong, namedWrong>>

Init ==
    /\ phase = [s \in Subs |-> "absent"]
    /\ unread = [s \in Subs |-> {}]
    /\ waitq = [s \in Subs |-> <<>>]
    /\ startq = [s \in Subs |-> {}]
    /\ kept = [s \in Subs |-> {}]
    /\ read = {}
    /\ dropped = {}
    /\ stoppedQ = {}
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
    /\ note = "none"
    /\ named = {}
    /\ noteWrong = FALSE
    /\ namedWrong = FALSE

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
    /\ UNCHANGED heldVars
    /\ UNCHANGED idleVars

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

\* A subagent that is being closed, whose work runs or whose close is not
\* written yet.
Marked(s) == phase[s] \in {"closing", "writing"}

\* A phase without the gap: the state the host's choice leaves to the world.
Plain(p) == IF p = "gap_idle" THEN "idle" ELSE IF p = "gap_next" THEN "starting" ELSE p

\* A message to it is queued, and goes with the close. fx never does: a
\* closing subagent refuses it. unmark_early is fx before settleClose kept
\* the mark until the write returned: a subagent whose work had ended was
\* neither marked nor gone, and took the message.
QueuesMarked(s) ==
    \/ phase[s] = "closing" /\ Bug = "queue_closing"
    \/ phase[s] = "writing" /\ Bug = "unmark_early"

\* fx before the start wait: a message to a starting turn waits for the next.
StartNextTurn(s) ==
    phase[s] = "starting" /\ Bug \in {"today", "start_next_turn"}

\* A call that waits for its subagent's turn to begin can't run yet.
SendRuns(c) == phase[c.sub] \notin Gaps /\ (phase[c.sub] # "starting" \/ StartNextTurn(c.sub))

\* The subagents other than `s` that are idle: what a start of a new `s`
\* must name.
IdleOthers(s) == {t \in Subs \ {s} : phase[t] \in {"idle", "gap_idle"}}

\* What fx names when a message starts a new subagent `s`.
NamedAtStart(s) ==
    CASE Bug = "before_idle" -> {}
      [] Bug = "names_busy" -> {t \in Subs \ {s} : phase[t] # "absent"}
      [] OTHER -> IdleOthers(s)

\* A message to a subagent that has a turn, or is closing or writing its close.
SendToBusy(s, m) ==
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
    \/ /\ Marked(s)
       /\ QueuesMarked(s)
       /\ waitq' = [waitq EXCEPT ![s] = Append(@, m)]
       /\ told' = [told EXCEPT ![m] = "waits"]
       /\ last' = Event("send", s, m, "waits", 0)
       /\ UNCHANGED <<phase, read, unread, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
    \/ /\ Marked(s)
       /\ ~QueuesMarked(s)
       /\ told' = [told EXCEPT ![m] = "refused"]
       /\ last' = Event("send", s, m, "refused", 0)
       /\ UNCHANGED <<phase, read, unread, waitq, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>

DoSend(c) ==
    LET s == c.sub
        m == c.msg
    IN
    /\ UNCHANGED heldVars
    /\ \/ /\ phase[s] \in {"absent", "idle"}
          /\ phase' = [phase EXCEPT ![s] = "starting"]
          /\ read' = read \cup {m}
          /\ told' = [told EXCEPT ![m] = "started"]
          /\ last' = Event("send", s, m, "started", 0)
          \* Only a new subagent's start names the idle ones.
          /\ named' = IF phase[s] = "absent" THEN NamedAtStart(s) ELSE {}
          /\ namedWrong' = (namedWrong \/ (phase[s] = "absent" /\ named' # IdleOthers(s)))
          /\ UNCHANGED <<unread, waitq, dropped, toldDropped, refusedOpen, coverBroken, stops, lateStart>>
       \/ /\ phase[s] \notin {"absent", "idle"}
          /\ named' = {}
          /\ UNCHANGED namedWrong
          /\ SendToBusy(s, m)

\* A stop drops the waiting messages now, and the stopped turn's unread ones
\* when it ends; its answer counts both.
DoStop(c) ==
    LET s == c.sub
        waiting == Range(waitq[s])
        held == startq[s]
        \* fx before the kept messages counted: a stop of an ended turn reached
        \* nothing, and the hook queued them.
        keptGap == phase[s] = "ended" /\ Bug = "leftover_gap"
        keptCounted == IF phase[s] = "ended" /\ Bug \notin {"leftover_gap", "leftover_uncounted"}
                       THEN kept[s] ELSE {}
        heldCounted == IF Bug = "gap_uncounted" THEN {} ELSE held
        counted == waiting \cup heldCounted \cup keptCounted \cup
            (IF phase[s] = "running" /\ Bug \notin {"today", "uncounted"}
             THEN unread[s] ELSE {})
    IN
    \* The close already ended the turn and dropped what waited: fx answers
    \* as for a second stop, and drops nothing more.
    \/ /\ Marked(s)
       /\ last' = Event("stop", s, NoMsg, "stopped", 0)
       /\ UNCHANGED <<phase, waitq, dropped, toldDropped, coverBroken>>
       /\ UNCHANGED heldVars
    \/ /\ phase[s] = "absent"
       /\ last' = Event("stop", s, NoMsg, "unavailable", 0)
       /\ UNCHANGED <<phase, waitq, dropped, toldDropped, coverBroken>>
       /\ UNCHANGED heldVars
    \* The work ended and none follows: nothing to stop (Owner.stop finds the
    \* slot ended). Only the planted defect answers as for a running turn.
    \/ /\ phase[s] = "gap_idle"
       /\ last' = Event("stop", s, NoMsg, IF Bug = "gap_blind" THEN "stopped" ELSE "idle", 0)
       /\ UNCHANGED <<phase, waitq, dropped, toldDropped, coverBroken>>
       /\ UNCHANGED heldVars
    \/ /\ phase[s] \notin {"closing", "writing", "absent", "gap_idle"}
       /\ phase' = [phase EXCEPT ![s] = IF @ \in {"starting", "running"} \/ (@ = "gap_next" /\ Bug # "gap_blind")
                                         THEN "ending_parent" ELSE @]
       /\ waitq' = [waitq EXCEPT ![s] = <<>>]
       /\ startq' = [startq EXCEPT ![s] = {}]
       /\ kept' = [kept EXCEPT ![s] = IF keptGap THEN @ ELSE {}]
       /\ dropped' = dropped \cup waiting \cup held \cup (IF keptGap THEN {} ELSE kept[s])
       /\ toldDropped' = toldDropped \cup counted
       /\ stoppedQ' = stoppedQ \cup waiting \cup held \cup unread[s] \cup kept[s]
       /\ coverBroken' = (coverBroken \/
            \E m \in waiting \cup unread[s] : <<m, c.id>> \in covered)
       \* A work that is still ending still counts as stopped.
       /\ last' = Event("stop", s, NoMsg,
                        IF phase[s] \in {"starting", "running", "gap_next"} \cup Endings THEN "stopped" ELSE "idle",
                        Cardinality(counted))

DoClose(c) ==
    LET s == c.sub
        lost == Range(waitq[s]) \cup unread[s] \cup startq[s] \cup kept[s]
        \* A turn a stop already ended had its unread messages counted by
        \* that stop; the close counts each message once, as a second stop
        \* does. It counts the work it drops before its turn began, and the
        \* messages the slot kept, as a stop does.
        keptCounted == IF Bug = "leftover_uncounted" THEN {} ELSE kept[s]
        heldCounted == IF Bug = "gap_uncounted" THEN {} ELSE startq[s]
        counted == Range(waitq[s]) \cup heldCounted \cup keptCounted \cup
            (IF phase[s] = "running" THEN unread[s] ELSE {})
    IN \/ /\ phase[s] = "absent"
          /\ last' = Event("close", s, NoMsg, "unavailable", 0)
          /\ UNCHANGED <<phase, waitq, unread, dropped, toldDropped>>
          /\ UNCHANGED heldVars
       \* A second close while the first is ending: fx answers closed and
       \* drops nothing more (`closeChild` in tool_host.zig).
       \/ /\ Marked(s)
          /\ last' = Event("close", s, NoMsg, "closed", 0)
          /\ UNCHANGED <<phase, waitq, unread, dropped, toldDropped>>
          /\ UNCHANGED heldVars
       \/ /\ phase[s] \notin {"closing", "writing", "absent"}
          \* A work that ended with none next closes as an idle one; the
          \* planted defect leaves the gap alone.
          /\ phase' = [phase EXCEPT ![s] =
                IF Bug = "gap_blind" /\ @ \in Gaps THEN @
                ELSE IF @ \in {"idle", "gap_idle"} THEN "absent" ELSE "closing"]
          /\ waitq' = [waitq EXCEPT ![s] = <<>>]
          /\ startq' = [startq EXCEPT ![s] = {}]
          /\ kept' = [kept EXCEPT ![s] = IF Bug = "close_leaves_kept" THEN @ ELSE {}]
          /\ unread' = [unread EXCEPT ![s] = {}]
          /\ dropped' = dropped \cup lost
          /\ toldDropped' = toldDropped \cup counted
          /\ stoppedQ' = stoppedQ \cup lost
          /\ last' = Event("close", s, NoMsg, "closed", Cardinality(counted))

Exec ==
    \E i \in 1..Len(step) :
        /\ Ready(i)
        /\ step[i].op = "send" => SendRuns(step[i])
        /\ step' = RemoveAt(step, i)
        /\ CASE step[i].op = "send" ->
                    DoSend(step[i]) /\ UNCHANGED <<note, noteWrong>>
             [] step[i].op = "stop" ->
                    DoStop(step[i]) /\ UNCHANGED <<unread, read, told, refusedOpen, stops, lateStart>>
                    /\ UNCHANGED idleVars
             [] step[i].op = "close" ->
                    DoClose(step[i]) /\ UNCHANGED <<read, told, refusedOpen, coverBroken, stops, lateStart>>
                    /\ UNCHANGED idleVars
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
    /\ UNCHANGED heldVars
    /\ UNCHANGED idleVars

\* A starting turn's worker begins: it takes messages from now on.
Begin(s) ==
    /\ phase[s] = "starting"
    /\ phase' = [phase EXCEPT ![s] = "running"]
    /\ read' = read \cup startq[s]
    /\ startq' = [startq EXCEPT ![s] = {}]
    /\ last' = Event("begin", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, waitq, kept, dropped, stoppedQ, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>
    /\ UNCHANGED idleVars

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
    /\ UNCHANGED heldVars
    /\ UNCHANGED idleVars

\* What fx tells main when `s`'s work ends: no report when main stopped or
\* closed it, and otherwise a report that says `s` is idle when no message
\* waits to start its next turn. fx decides it before the next turn takes
\* the waiting messages.
EndNote(s, reports) ==
    CASE ~reports -> "none"
      [] Bug = "before_idle" -> "plain"
      \* Decided after the next turn took the waiting messages.
      [] Bug = "note_after_take" -> "idle"
      [] OTHER -> IF waitq[s] = <<>> /\ kept[s] = {} THEN "idle" ELSE "plain"

\* Sets the note of `s`'s end, which goes to `after`, and whether it was
\* wrong: a report must say idle exactly when the end leaves `s` idle.
Noted(s, reports, after) ==
    /\ note' = EndNote(s, reports)
    /\ noteWrong' = (noteWrong \/
         IF reports THEN (note' = "idle") # (after = "idle") ELSE note' # "none")
    /\ UNCHANGED <<named, namedWrong>>

\* The running turn ends on its own; waiting messages start the next one. With
\* `gap`, the slot has not gone on yet: the host has chosen, but the next turn
\* has not started and the end is not published (Publish).
FinishWith(s, gap) ==
    /\ phase[s] = "running"
    /\ unread[s] = {}
    /\ IF waitq[s] = <<>>
       THEN /\ phase' = [phase EXCEPT ![s] = IF gap THEN "gap_idle" ELSE "idle"]
            /\ UNCHANGED <<waitq, startq>>
       ELSE /\ startq' = [startq EXCEPT ![s] = Range(waitq[s])]
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = IF gap THEN "gap_next" ELSE "starting"]
    /\ last' = Event("finish", s, NoMsg, "none", 0)
    \* A turn that ended on its own reports to main.
    /\ Noted(s, TRUE, Plain(phase'[s]))
    /\ UNCHANGED <<unread, kept, read, dropped, stoppedQ, toldDropped, told, sent, stops, steps, step,
                   covered, refusedOpen, coverBroken, lateStart>>

Finish(s) == FinishWith(s, FALSE)
FinishInGap(s) == FinishWith(s, TRUE)

\* The slot goes on: it starts the chosen next turn, or publishes that the
\* work is done.
Publish(s) ==
    /\ phase[s] \in Gaps
    /\ phase' = [phase EXCEPT ![s] = IF @ = "gap_idle" THEN "idle" ELSE "starting"]
    /\ last' = Event("publish", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, waitq, read, dropped, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>
    /\ UNCHANGED heldVars
    /\ UNCHANGED idleVars

\* The stopped turn ends: its unread messages go, and the waiting ones start
\* the next turn. A closed subagent's work ends, and its close is written
\* next (WriteClose); it is closing until then.
EndStoppedWith(s, gap) ==
    /\ phase[s] \in Endings \cup {"closing"}
    /\ gap => (phase[s] \in Endings /\ Bug # "drop_waiting_at_end")
    /\ unread' = [unread EXCEPT ![s] = {}]
    /\ IF Bug = "drop_waiting_at_end"
       THEN /\ dropped' = dropped \cup unread[s] \cup Range(waitq[s])
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = "idle"]
            /\ UNCHANGED startq
       ELSE IF phase[s] = "closing"
       THEN /\ dropped' = dropped \cup unread[s] \cup Range(waitq[s])
            /\ waitq' = [waitq EXCEPT ![s] = <<>>]
            /\ phase' = [phase EXCEPT ![s] = "writing"]
            /\ UNCHANGED startq
       ELSE /\ dropped' = dropped \cup unread[s]
            /\ IF waitq[s] = <<>>
               THEN /\ phase' = [phase EXCEPT ![s] = IF gap THEN "gap_idle" ELSE "idle"]
                    /\ UNCHANGED <<waitq, startq>>
               ELSE /\ startq' = [startq EXCEPT ![s] = Range(waitq[s])]
                    /\ waitq' = [waitq EXCEPT ![s] = <<>>]
                    /\ phase' = [phase EXCEPT ![s] = IF gap THEN "gap_next" ELSE "starting"]
    /\ last' = Event("end", s, NoMsg, "none", Cardinality(Range(waitq[s])))
    \* Only a turn the user stopped reports; main's own stop or close
    \* already answered.
    /\ Noted(s, phase[s] = "ending_user", Plain(phase'[s]))
    /\ UNCHANGED <<toldDropped, stoppedQ, kept, read, told, sent, stops, steps, step, covered,
                   refusedOpen, coverBroken, lateStart>>

EndStopped(s) == EndStoppedWith(s, FALSE)
EndStoppedInGap(s) == EndStoppedWith(s, TRUE)

\* The running turn ends without reading what joined it, as a failed or
\* cancelled request ends it. Its slot keeps those messages (`keepLeftovers`)
\* until the end hook queues them. A stop or close that lands now must count
\* them and drop them: main has been told they joined a turn.
Fail(s) ==
    /\ phase[s] = "running"
    /\ unread[s] # {}
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ kept' = [kept EXCEPT ![s] = unread[s]]
    /\ unread' = [unread EXCEPT ![s] = {}]
    /\ last' = Event("fail", s, NoMsg, "none", 0)
    /\ UNCHANGED <<waitq, startq, stoppedQ, read, dropped, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>
    /\ UNCHANGED idleVars

\* The work the host chose for the slot fails before its worker begins, as a
\* failed bind to its agent does. Its failed report tells main that its
\* messages never ran, so no stop or close counts them again, and the slot's
\* count of them ends with it (`slotMain` zeroes `unstarted` where it records
\* the end); the end hook then runs as after any turn.
FailStart(s) ==
    /\ phase[s] = "starting"
    /\ startq[s] # {}
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ startq' = [startq EXCEPT ![s] = IF Bug = "stale_unstarted" THEN @ ELSE {}]
    /\ dropped' = dropped \cup startq[s]
    /\ toldDropped' = toldDropped \cup startq[s]
    /\ last' = Event("fail_start", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, waitq, kept, stoppedQ, read, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>
    /\ UNCHANGED idleVars

\* The end hook of an ended turn queues the kept messages ahead of the
\* waiting ones as the next work (`queueLeftoversLocked`, once
\* `handOverLeftovers` allowed it), and the host chooses it: the gap, where
\* the slot has not begun its turn. The turn failed, so it reports. Nothing
\* to queue leaves the subagent idle.
Hook(s) ==
    /\ phase[s] = "ended"
    /\ LET queued == kept[s] \cup Range(waitq[s])
       IN /\ startq' = [startq EXCEPT ![s] = queued]
          /\ phase' = [phase EXCEPT ![s] = IF queued = {} THEN "gap_idle" ELSE "gap_next"]
    /\ kept' = [kept EXCEPT ![s] = {}]
    /\ waitq' = [waitq EXCEPT ![s] = <<>>]
    /\ last' = Event("hook", s, NoMsg, "none", 0)
    /\ Noted(s, TRUE, Plain(phase'[s]))
    /\ UNCHANGED <<unread, read, dropped, stoppedQ, toldDropped, told, sent, stops, steps, step,
                   covered, refusedOpen, coverBroken, lateStart>>

\* A closed subagent's close is written once nothing of it runs: the registry
\* drops it, and a new one may take the name (Runtime.settleClose).
WriteClose(s) ==
    /\ phase[s] = "writing"
    /\ phase' = [phase EXCEPT ![s] = "absent"]
    /\ last' = Event("write_close", s, NoMsg, "none", 0)
    /\ UNCHANGED <<unread, waitq, read, dropped, toldDropped, told, sent, stops, steps,
                   step, covered, refusedOpen, coverBroken, lateStart>>
    /\ UNCHANGED heldVars
    /\ UNCHANGED idleVars

Next ==
    \/ NewStep
    \/ Exec
    \/ \E s \in Subs : UserStop(s) \/ Begin(s) \/ Read(s) \/ Finish(s) \/ EndStopped(s)
                       \/ WriteClose(s) \/ FinishInGap(s) \/ EndStoppedInGap(s) \/ Publish(s)
    \/ \E s \in Subs : Fail(s) \/ Hook(s) \/ FailStart(s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The rules.                                                               *)

TypeOK ==
    /\ phase \in [Subs -> AllPhases]
    /\ unread \in [Subs -> SUBSET Msgs]
    /\ \A s \in Subs : Range(waitq[s]) \subseteq Msgs
    /\ startq \in [Subs -> SUBSET Msgs]
    /\ kept \in [Subs -> SUBSET Msgs]
    /\ stoppedQ \subseteq Msgs
    /\ read \subseteq Msgs
    /\ dropped \subseteq Msgs
    /\ toldDropped \subseteq Msgs
    /\ told \in [Msgs -> Answers]
    /\ sent \subseteq Msgs
    /\ refusedOpen \subseteq Msgs
    /\ coverBroken \in BOOLEAN
    /\ lateStart \subseteq Msgs
    /\ last.op \in AllOps
    /\ note \in Notes
    /\ named \subseteq Subs
    /\ noteWrong \in BOOLEAN
    /\ namedWrong \in BOOLEAN

\* Main hears of every message fx throws away.
NoSilentLoss == dropped \subseteq toldDropped

\* A count never includes a message the subagent read.
CountedNeverRead == toldDropped \cap read = {}

\* A message is refused only while its subagent is being closed.
RefusedOnlyWhenClosing == refusedOpen = {}

\* A stop never drops a message main wrote after it in the same step.
StopRunsFirst == ~coverBroken

\* A subagent that is being closed holds no message, waiting or unread: it
\* would go with the close, unheard of. Runtime.settleClose keeps the mark,
\* and with it the refusal, until the close is written.
ClosingHoldsNothing ==
    \A s \in Subs : Marked(s) => waitq[s] = <<>> /\ unread[s] = {}

\* A message queued, kept or unread when a stop or close of its subagent
\* answered is never read: the stop holds across the end hook, which queues
\* the kept messages, and across the choice of the next work.
StopHoldsForQueued == stoppedQ \cap read = {}

\* Nor does a subagent that is being closed hold a message its slot kept from a
\* turn that ended without reading it, or one the next work carries: the close
\* drops and counts them (`Owner.takeDropped`, `Owner.stop`).
ClosingHoldsNoKept ==
    \A s \in Subs : Marked(s) => startq[s] = {} /\ kept[s] = {}

\* A work's messages are accounted for by its end: once the end is recorded the
\* slot counts none of them as unstarted any more, so a stop or close in the
\* gap after it does not count them again (`slot.unstarted = 0` where
\* `slotMain` records the end).
UnstartedGone == \A s \in Subs : phase[s] = "ended" => startq[s] = {}

\* A stop or close that answers it ended the subagent's turn, or closed the
\* subagent, leaves it ending, closing or gone: never running on in the gap
\* after its work ended. So a stop in the gap finds nothing to stop or stops
\* the turn that follows, and a close leaves no extra turn
\* (Owner.markNext, Owner.stop, Owner.closeByUser).
GapStopHonest ==
    /\ (last.op = "stop" /\ last.answer = "stopped") =>
           phase[last.sub] \in Endings \cup {"closing", "writing"}
    /\ (last.op = "close" /\ last.answer = "closed") =>
           phase[last.sub] \in {"closing", "writing", "absent"}

\* A message main sends to a turn that is still starting joins that turn:
\* fx never holds it for a later one (Owner.steer's .starting).
JoinsStartingWork == lateStart = {}

\* A report says its subagent is idle exactly when its end leaves it idle:
\* never when a waiting message starts its next turn, and always when
\* nothing does. An end main stopped or closed sends no report.
IdleNoteHonest == ~noteWrong

\* A message that starts a new subagent names exactly the other subagents
\* that are idle: none that works, starts, ends, or closes, and every idle
\* one.
NamesTheIdle == ~namedWrong

\* Once main's steps have run and no subagent works, each message main
\* sent was read, counted as dropped, or refused while a close was under way.
Accounted ==
    (step = <<>> /\ \A s \in Subs : phase[s] \in {"absent", "idle"}) =>
        \A m \in sent : m \in read \cup toldDropped \/ told[m] = "refused"
=============================================================================
