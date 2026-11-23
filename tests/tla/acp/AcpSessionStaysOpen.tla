---- MODULE AcpSessionStaysOpen ----
(*
A session that stays open after its first client leaves. Design B of this model
is built in src/acp/: the session's members are kept in join order, and the first
of them is the main client. Designs A and current are kept for comparison. The
rules it checks are the rules of four
sections of src/protocol/spec/sh-fx.md, as the change extends them: "Following
a session", "Steering and queued prompts" (with "Stopping and withdrawing"),
"Permission requests", and "Keeping turns after a disconnect".

One session, three clients: O opens it, and O's connection is the stdio
connection, so O's input end is the process's stdin end. J1 and J2 are
leader-socket clients. Each client may join, leave (session/close, or its
input ends), send a prompt, cancel the running turn, answer the turn's
permission request, or set the mode. The turn asks for permission. The process
may crash, and it exits once stdin has ended and nothing is left to serve.

Designs, selected by the constant Design:
- "current": the session belongs to O's connection, as src/acp/server.zig did
  before design B (closeSession and closeAllSessions). O's leave closes the session for
  every client. The followers stay listed until they leave, and their requests
  get -32002 meanwhile. A leaving follower's waiting input is withdrawn, as
  src/acp/server.zig does today.
- "A": hand-off. The owner pointer moves to the oldest remaining member when
  the owner leaves, and is cleared when no member is left. A turn asks the
  current owner each time.
- "B", built: process-owned members in join order. The main is the first member, and
  each request asks the first member at that moment.

Rules the model checks, in plain words:
- Leaving while another member remains ("Stopping and withdrawing"): the
  leaver's queued prompts and untaken steers are withdrawn. A close answers
  them as cancelled, and an input end traces them. A running turn that the
  leaver's prompt started goes on, and its permission requests go to the next
  main. The model keeps steers in the queue with prompts, so the queue stands
  for both.
- The last member's leave ("Keeping turns after a disconnect"): a close
  cancels the closer's own running turn and answers its own queued prompts as
  cancelled. An input end with keep lets its turn finish and its queued prompts
  run. An input end without keep stops its turn, saved as interrupted, and its
  queued prompts still run.
- Left work: no close or leave cancels or answers another client's left work.
  Left work is a turn or queued prompt that an earlier last leave left behind,
  or a running turn whose sender left while others remained. A leave never
  cancels another member's running turn either.
- A queued prompt that a last leave left behind leaves the queue only by
  starting its turn.
- A join does not change the queue, so a join never removes left work.
- The session closes once no member remains and no left work runs or waits.
- After the main client leaves, the next client in join order takes the turn's
  permission requests. A request is denied only when no member remains.
- The successor takes the mode and the settings. Closing the session for every
  client is not part of its role.
- The process exits once stdin has ended, no session has a client, and no turn
  runs.
- Only the main client's mode change applies.

Not modelled: host tools and journals, byte limits, a full disk, a slow peer,
the accept limit, and the traces. Permission requests stay design text in the
"Permission requests" section until the next slice, so the model keeps one
answering client.

Abstractions, which change no membership or turn state:
- No bytes. MaxQueue stands for the 64-entry queue.
- One permission request at a time. Joins and prompts are bounded, so the state
  space is finite.
*)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Design, Mutant, Class, MaxQueue

Owner == "O"
Clients == {"O", "J1", "J2"}

VARIABLE s

\* The members, in join order.
Mem(x) == {x.members[i] : i \in 1..Len(x.members)}

InQ(q, c) == \E i \in 1..Len(q) : q[i] = c

Queued(x, c) == InQ(x.queue, c)

\* The main client: the first member in B. In current and A it is the owner pointer.
Main(x) ==
  IF Design = "B"
  THEN IF x.members = <<>> THEN "none" ELSE x.members[1]
  ELSE x.owner

Without(q, c) == SelectSeq(q, LAMBDA x : x # c)

\* A's hand-off target: the oldest remaining member, or the newest under the mutant.
NewOwner(rest) ==
  IF Design = "A"
  THEN IF Mutant = "aNewest" THEN rest[Len(rest)] ELSE rest[1]
  ELSE s.owner

NewMain(rest) == IF Design = "A" THEN NewOwner(rest) ELSE rest[1]

\* The mutants aFree and bFree keep a turn running after its last member has gone.
FreeMutant == (Mutant = "aFree" /\ Design = "A") \/ (Mutant = "bFree" /\ Design = "B")

\* The clients of left work that are still queued after a change to the queue.
Pruned(left, q) == {d \in left : InQ(q, d)}

\* The next queued prompt starts a turn, or the turn goes idle.
StartNext(x) ==
  IF x.queue = <<>>
  THEN [x EXCEPT !.turn = "idle", !.turnSender = "none", !.lastLeft = {}]
  ELSE [x EXCEPT !.turn = "running", !.turnSender = Head(x.queue),
                 !.queue = Tail(x.queue), !.lastLeft = Pruned(x.lastLeft, Tail(x.queue))]

\* lastLeft holds the queued prompts that a last leave left behind. A queued prompt of a
\* client that left while another member remained is withdrawn by its leave, so it is
\* never in the queue at all.
Init ==
  \E k \in [Clients -> BOOLEAN] :
    s = [members |-> <<Owner>>, sess |-> TRUE, owner |-> Owner,
         conn |-> [c \in Clients |-> TRUE], keep |-> k,
         turn |-> "idle", turnSender |-> "none", queue |-> <<>>, lastLeft |-> {},
         askOpen |-> FALSE, askTo |-> "none", askEnd |-> "none",
         procAlive |-> TRUE, crashed |-> FALSE, modeSetBy |-> "none",
         joinsLeft |-> 2, promptsLeft |-> 3, asksLeft |-> 2]

\* A client joins the open session. A join never changes the queue. The mutant
\* joinWithdraws empties the queue, and the left work in it, when a client joins a
\* session with no member.
Join(c) ==
  /\ s.procAlive /\ s.sess /\ c \notin Mem(s) /\ s.conn[c] /\ s.joinsLeft > 0
  /\ s' = [s EXCEPT !.members = Append(s.members, c),
                    !.owner = IF Design = "A" /\ s.members = <<>> THEN c ELSE s.owner,
                    !.queue = IF Mutant = "joinWithdraws" /\ s.members = <<>> THEN <<>> ELSE s.queue,
                    !.lastLeft = IF Mutant = "joinWithdraws" /\ s.members = <<>> THEN {} ELSE s.lastLeft,
                    !.joinsLeft = s.joinsLeft - 1]

\* current: the owner's leave closes the session for everyone (closeSession and
\* closeAllSessions in src/acp/server.zig). The followers stay listed until they leave.
CurrentOwnerLeave(c, kind) ==
  [s EXCEPT !.members = Without(s.members, c), !.sess = FALSE,
            !.turn = "idle", !.turnSender = "none", !.queue = <<>>, !.lastLeft = {},
            !.askOpen = FALSE, !.askTo = "none",
            !.askEnd = IF s.askOpen THEN "denied" ELSE s.askEnd,
            !.conn = IF kind = "input" THEN [s.conn EXCEPT ![c] = FALSE] ELSE s.conn]

\* A member leaves, by a close (kind "close") or an input end (kind "input").
\* While another member remains, the leaver's queued prompts are withdrawn and its running
\* turn goes on. When the last member leaves, a close cancels its own running turn and
\* answers its queued prompts as cancelled; an input end keeps the turn only with keep,
\* and its queued prompts stay as left work. A leave never cancels or answers another
\* client's turn or queued prompt. The mutant closeCancelsOthers cancels a running turn of
\* another client on the last member's close. The mutant leaveKeepsQueue keeps a leaver's
\* queue on an input end while another member remains.
LeaveOwn(c, kind) ==
  LET rest == Without(s.members, c)
      lastLeave == rest = <<>>
      runningOwn == s.turn = "running" /\ s.turnSender = c
      cancelOwn == runningOwn /\ lastLeave
                   /\ (kind = "close" \/ (~s.keep[c] /\ Mutant # "lastNoCancel"))
      cancelOther == Mutant = "closeCancelsOthers" /\ kind = "close" /\ lastLeave
                     /\ s.turn = "running"
      cancelRunning == cancelOwn \/ cancelOther
      withdrawn == kind = "close" \/ (~lastLeave /\ Mutant # "leaveKeepsQueue")
      q1 == IF withdrawn THEN Without(s.queue, c) ELSE s.queue
      left1 == Pruned(s.lastLeft, q1)
               \cup (IF lastLeave /\ kind = "input" /\ InQ(q1, c) THEN {c} ELSE {})
      x1 == [s EXCEPT !.members = rest,
                      !.queue = q1,
                      !.lastLeft = left1,
                      !.owner = IF Design = "A" /\ Main(s) = c
                                THEN IF rest = <<>> THEN "none" ELSE NewOwner(rest)
                                ELSE s.owner,
                      !.conn = IF kind = "input" THEN [s.conn EXCEPT ![c] = FALSE] ELSE s.conn]
      x2 == IF cancelRunning
            THEN StartNext([x1 EXCEPT !.askOpen = FALSE, !.askTo = "none",
                                      !.askEnd = IF s.askOpen
                                                 THEN (IF rest = <<>> THEN "denied" ELSE "cancelled")
                                                 ELSE s.askEnd])
            ELSE IF s.askOpen /\ Main(s) = c
                 THEN IF rest = <<>>
                      THEN [x1 EXCEPT !.askOpen = FALSE, !.askTo = "none", !.askEnd = "denied"]
                      ELSE [x1 EXCEPT !.askTo = IF Mutant = "aCaptured" /\ Design = "A"
                                                THEN s.askTo ELSE NewMain(rest)]
                 ELSE x1
  IN [x2 EXCEPT !.sess = IF FreeMutant /\ rest = <<>> /\ x2.turn = "running" THEN FALSE ELSE x2.sess]

\* A member leaves, by session/close or by its input ending.
Leave(c, kind) ==
  /\ s.procAlive
  /\ c \in Mem(s)
  /\ s' = IF Design = "current" /\ c = s.owner THEN CurrentOwnerLeave(c, kind) ELSE LeaveOwn(c, kind)

\* A client's input ends. A client that is not a member only loses its connection.
InputEnd(c) ==
  /\ Class = "all"
  /\ s.conn[c]
  /\ IF c \in Mem(s)
     THEN Leave(c, "input")
     ELSE s' = [s EXCEPT !.conn = [s.conn EXCEPT ![c] = FALSE]]

\* A member sends a prompt. It starts a turn, or it waits in the queue behind the running turn.
Prompt(c) ==
  /\ s.procAlive /\ s.sess /\ c \in Mem(s) /\ s.promptsLeft > 0 /\ ~Queued(s, c)
  /\ IF s.turn = "idle"
     THEN s' = [s EXCEPT !.turn = "running", !.turnSender = c, !.promptsLeft = s.promptsLeft - 1]
     ELSE /\ Len(s.queue) < MaxQueue
          /\ s' = [s EXCEPT !.queue = Append(s.queue, c), !.promptsLeft = s.promptsLeft - 1]

\* The running turn asks for permission from the current main (PermissionToMain).
AskPerm ==
  /\ s.procAlive /\ s.sess /\ s.turn = "running" /\ ~s.askOpen
  /\ s.members # <<>> /\ s.asksLeft > 0
  /\ s' = [s EXCEPT !.askOpen = TRUE, !.askTo = Main(s), !.askEnd = "none",
                    !.asksLeft = s.asksLeft - 1]

\* The addressed client answers the open request.
Answer(c) ==
  /\ s.procAlive /\ s.askOpen /\ s.askTo = c /\ s.conn[c] /\ c \in Mem(s)
  /\ s' = [s EXCEPT !.askOpen = FALSE, !.askTo = "none", !.askEnd = "answered"]

\* The running turn ends once no question is open.
TurnFinish ==
  /\ s.procAlive /\ s.turn = "running" /\ ~s.askOpen
  /\ s' = StartNext(s)

\* A member sends session/cancel. The open question is cancelled, and the turn ends.
CancelTurn(c) ==
  /\ s.procAlive /\ s.sess /\ s.turn = "running" /\ c \in Mem(s)
  /\ s' = StartNext([s EXCEPT !.askOpen = FALSE, !.askTo = "none",
                              !.askEnd = IF s.askOpen THEN "cancelled" ELSE s.askEnd])

\* No member, no turn, no queued prompt: the session closes.
SessEnd ==
  /\ s.sess /\ s.members = <<>> /\ s.turn = "idle" /\ s.queue = <<>>
  /\ s' = [s EXCEPT !.sess = FALSE]

\* A member sets the mode. Only the main's change applies (MainChangesModeOnly).
SetMode(c) ==
  /\ s.procAlive /\ s.sess /\ c \in Mem(s)
  /\ (c = Main(s) \/ Mutant = "modeAny")
  /\ s' = [s EXCEPT !.modeSetBy = c]

\* The process crashes. Its memory and its connections are gone (Class all only).
Crash ==
  /\ Class = "all" /\ s.procAlive /\ ~s.crashed
  /\ s' = [s EXCEPT !.procAlive = FALSE, !.crashed = TRUE, !.members = <<>>,
                    !.sess = FALSE, !.owner = "none", !.conn = [c \in Clients |-> FALSE],
                    !.turn = "idle", !.turnSender = "none", !.queue = <<>>, !.lastLeft = {},
                    !.askOpen = FALSE, !.askTo = "none"]

\* Stdin has ended, no member, no turn, no session: the process exits.
ProcExit ==
  /\ s.procAlive /\ ~s.conn[Owner] /\ s.members = <<>> /\ s.turn = "idle" /\ ~s.sess
  /\ s' = [s EXCEPT !.procAlive = FALSE]

\* The mutant exits while a member is still served.
ExitEarly ==
  /\ Mutant = "exitEarly" /\ s.procAlive /\ ~s.conn[Owner] /\ s.members # <<>>
  /\ s' = [s EXCEPT !.procAlive = FALSE]

Next ==
  \/ \E c \in Clients : Join(c)
  \/ \E c \in Clients : Leave(c, "close")
  \/ \E c \in Clients : InputEnd(c)
  \/ \E c \in Clients : Prompt(c)
  \/ AskPerm
  \/ \E c \in Clients : Answer(c)
  \/ TurnFinish
  \/ \E c \in Clients : CancelTurn(c)
  \/ SessEnd
  \/ \E c \in Clients : SetMode(c)
  \/ Crash
  \/ ProcExit
  \/ ExitEarly

Fairness == WF_s(TurnFinish) /\ WF_s(SessEnd) /\ WF_s(ProcExit) /\ WF_s(\E c \in Clients : Answer(c))

Spec == Init /\ [][Next]_s /\ Fairness

\* While any member has the session, it is open ("Following a session").
StaysOpenWhileMember == s.members # <<>> => s.sess

\* The session is freed only when no member remains and no left work runs or waits.
SessionFreedWhenIdle == (~s.sess) => (s.members = <<>> /\ s.turn = "idle" /\ s.queue = <<>>)

\* With members, exactly one main, the oldest in join order ("Following a session").
OneMainInJoinOrder == s.members # <<>> => Main(s) = s.members[1]

\* An open question goes to the current main, and only while a member remains ("Permission requests").
PermissionToMain == s.askOpen => (s.members # <<>> /\ s.askTo = Main(s))

\* The session, its turn and its open question never name a client that has left. A running
\* turn may outlive its sender while members remain (see Left work in the header): its answer
\* is then dropped with a trace, as answerSender does with sender_left in src/acp/server.zig.
NoDanglingClient ==
  /\ (s.askOpen => (s.askTo \in Mem(s)))
  /\ (Design = "A" => IF s.members = <<>> THEN s.owner = "none" ELSE s.owner \in Mem(s))
  /\ (s.turn = "running" => s.sess)

\* The process is gone only when no member and no turn remain.
NoExitWhileServing == ~s.procAlive => (s.members = <<>> /\ s.turn = "idle" /\ ~s.sess)

\* Only the main's mode change applies.
MainChangesModeOnly ==
  [][ (s'.modeSetBy # s.modeSetBy /\ s'.modeSetBy # "none") => (s'.modeSetBy = Main(s)) ]_s

\* A question is denied only by the step that removes the last member.
DeniedOnlyWhenNoMember ==
  [][ (s'.askEnd = "denied" /\ s.askEnd # "denied") => (s'.members = <<>>) ]_s

\* Once stdin has ended and the last member has left and the turn has ended, the process
\* exits, unless a client joins first and the session is no longer idle. A join after idle
\* is not a failure, so the property is "idle leads to exit or to a change out of idle".
Idle == ~s.conn[Owner] /\ s.members = <<>> /\ s.turn = "idle"
ExitsWhenIdle == Idle ~> (~s.procAlive \/ ~Idle)

\* Leaving while another member remains: a prompt that its sender left behind never starts a
\* turn. Such a prompt is withdrawn by its leave, so no step may start a queued prompt whose
\* sender is not a member, unless a last leave left it behind (lastLeft).
LeftInputNeverRuns ==
  [][ ~ (\E d \in Clients :
           /\ Queued(s, d) /\ d \notin Mem(s) /\ d \notin s.lastLeft
           /\ s'.turn = "running" /\ s'.turnSender = d /\ s'.procAlive) ]_s

\* The last member's leave: a queued prompt that it left behind leaves the queue only by
\* starting its turn. A join, a leave or a close of another client does not remove it. The
\* name is kept from the keep case that started the rule.
LastKeepQueueRuns ==
  [][ \A d \in Clients :
        (d \in s.lastLeft /\ Queued(s, d) /\ ~Queued(s', d) /\ s'.procAlive)
          => s'.turnSender = d ]_s

\* Left work: a close or a leave by one client never cancels a running turn of another client,
\* and never removes another client's queued prompt except by starting it. The queue clause
\* also covers the members' own queued prompts, which a leave of another member must not touch.
LeaveAffectsOnlyOwnInput ==
  [][ \A c \in Clients :
        (c \in Mem(s) /\ c \notin Mem(s') /\ s'.procAlive) =>
          ( ((s.turn = "running" /\ s.turnSender # c) => (s'.turn = "running" /\ s'.turnSender = s.turnSender))
            /\ (\A d \in Clients : (d # c /\ Queued(s, d) /\ ~Queued(s', d)) => s'.turnSender = d) ) ]_s

\* The last member's leave: its own running turn stays running after its input ends only when
\* the member kept it ("Keeping turns after a disconnect"). The queue must not move in that
\* step, so a queued prompt that starts in the step is not counted. The rule is an action
\* because the keep flag and the leave are both part of the step.
LastLeaverRule ==
  [][ \A c \in Clients :
        (s.members = <<c>> /\ s'.members = <<>> /\ s.turn = "running" /\ s.turnSender = c
         /\ s'.turn = "running" /\ s'.turnSender = c /\ s'.queue = s.queue)
          => (s.keep[c] /\ s.conn[c] /\ ~s'.conn[c]) ]_s

====
