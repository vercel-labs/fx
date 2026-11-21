----------------------------- MODULE AcpSharedInput -----------------------------
(***************************************************************************)
(* Two clients on one session: the owner O, and a follower F that joins it. *)
(* Each present client sends prompts with delivery none, steer or queue,    *)
(* cancels, and (F only) closes or disconnects; F loads with a system        *)
(* prompt. The model covers the input side of "Following a session" in      *)
(* src/protocol/spec/sh-fx.md: every client may send prompts, fx keeps one  *)
(* order for the input of all clients, and each answer and user chunk goes  *)
(* where that section says.                                                 *)
(*                                                                         *)
(* Rules TRUE is what fx does now for a follower: its prompts, steers and  *)
(* cancels take part, and its load's system prompt applies from the next   *)
(* turn. Rules FALSE is the older behavior, where a follower only watches: *)
(* its prompt, steer and cancel are refused, and its load's system prompt  *)
(* is ignored.                                                             *)
(*                                                                         *)
(* Size: the owner sends MaxSends prompts and the follower sends FollowerSends *)
(* (one). Two queued prompts, one from each client, are the smallest input  *)
(* that shows the queue order, and one follower prompt is enough for each   *)
(* follower rule.                                                           *)
(*                                                                         *)
(* A request is named by its sender and its number, <<client, n>>. Its      *)
(* status is one of: unsent; refused (answered at once); queued; pending (a  *)
(* steer that waits for the turn's next safe point); turn (the running     *)
(* turn's prompt); absorbed (a steer the running turn took); done (its turn  *)
(* ended normally, and the answer went to a present sender); stopped (its    *)
(* turn ended cancelled, and the answer carries stopReason cancelled);      *)
(* cancelled (withdrawn when its sender closed, and answered with -32800);  *)
(* withdrawn (withdrawn when its sender disconnected, and not answered).    *)
(* Answered means refused, done, stopped or cancelled.                      *)
(*                                                                         *)
(* What each client has received is kept per request: chunkTo[r] is the set *)
(* of clients that got r's user chunk, and the answer goes to r's sender.   *)
(* Ghost variables record what each rule needs to be checked:               *)
(*   endReason, lastEnded: how the last ended turn ended, and which turn.   *)
(*   cancelIgnored: a cancel from a client that may not stop the turn was    *)
(*     handled while a turn ran, and the turn went on.                      *)
(*   sysBefore: the session's prompt before the last load.                  *)
(*   atStart: the session's prompt when the running turn started.           *)
(* The other ghosts record each broken delivery rule at the moment it       *)
(* happens, so a planted bug is caught where it breaks the rule.            *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Rules, MaxSends, FollowerSends

Owner == "owner"
Follower == "follower"
Clients == {Owner, Follower}
Sys == {"old", "new"}
Kinds == {"none", "steer", "queue"}
EndReasons == {"none", "end_turn", "cancelled"}
Req == {<<Owner, n>> : n \in 1..MaxSends} \cup {<<Follower, n>> : n \in 1..FollowerSends}
NoReq == <<"none", 0>>

VARIABLES
  fstate,         \* the follower: "absent", "present" or "gone"
  status,         \* the status of each request, as the comment above lists
  kindOf,         \* the delivery each sent request carries
  queue,          \* queued prompts, in the order they arrived
  turn,           \* the running turn's request, or NoReq
  turnStart,      \* the system prompt the running turn keeps (it never changes during the turn)
  turnSys,        \* the system prompt the running turn sends
  sysNow,         \* the session's current client system prompt
  sysBefore,      \* ghost: the session's prompt before the last load
  atStart,        \* ghost: the session's prompt when the running turn started
  chunkTo,        \* the clients that got each request's user chunk
  cancelPending,  \* per client: a session/cancel it sent that is not handled
  cancelIgnored,  \* ghost: a cancel from a client that may not stop the turn was handled while a turn ran
  endReason,      \* ghost: how the last ended turn ended
  lastEnded,      \* ghost: the request of the last ended turn, or NoReq
  misrouted,      \* ghost: an answer went to a client other than its sender
  twice,          \* ghost: a request was answered a second time
  echoBroken,     \* ghost: a prompt's chunk missed a present client
  orderBroken,    \* ghost: a queued prompt started before one that arrived earlier
  leftRan         \* ghost: input from a client that had left started or was taken

vars == <<fstate, status, kindOf, queue, turn, turnStart, turnSys, sysNow, sysBefore,
          atStart, chunkTo, cancelPending, cancelIgnored, endReason, lastEnded,
          misrouted, twice, echoBroken, orderBroken, leftRan>>

Present(c) == IF c = Owner THEN TRUE ELSE fstate = "present"
PresentSet == {c \in Clients : Present(c)}
Refused(c) == c = Follower /\ ~Rules
MayCancel(c) == c = Owner \/ Rules
Recipient(r) == r[1]
EchoTo(r) == PresentSet \ {r[1]}
StartPrompt == sysNow
Wanted(r) == (r[1] = Follower) /\ (kindOf[r] \in {"steer", "queue"})
Pending == {r \in Req : status[r] = "pending"}
Taken(r) == status[r] \in {"turn", "absorbed", "done", "stopped"}
Answered(r) == status[r] \in {"refused", "done", "stopped", "cancelled"}
NextQueued == IF queue = <<>> THEN NoReq ELSE queue[1]
RestQueued == IF queue = <<>> THEN <<>> ELSE Tail(queue)

RECURSIVE Without(_, _)
\* The queue without the prompts of client c, in order.
Without(q, c) ==
  IF q = <<>> THEN <<>>
  ELSE IF q[1][1] = c THEN Without(Tail(q), c)
  ELSE <<q[1]>> \o Without(Tail(q), c)

Init ==
  /\ fstate = "absent"
  /\ status = [r \in Req |-> "unsent"]
  /\ kindOf = [r \in Req |-> "none"]
  /\ queue = <<>>
  /\ turn = NoReq
  /\ turnStart = "old"
  /\ turnSys = "old"
  /\ sysNow = "old"
  /\ sysBefore = "old"
  /\ atStart = "old"
  /\ chunkTo = [r \in Req |-> {}]
  /\ cancelPending = [c \in Clients |-> FALSE]
  /\ cancelIgnored = FALSE
  /\ endReason = "none"
  /\ lastEnded = NoReq
  /\ misrouted = FALSE
  /\ twice = FALSE
  /\ echoBroken = FALSE
  /\ orderBroken = FALSE
  /\ leftRan = FALSE

\* server.zig: decideSessionPrompt and claimTurnLocked, for a prompt that
\* arrives when no turn runs. The follower's prompt takes the same path through
\* promptFromFollower. The turn starts at once with the session's current
\* prompt (StartPrompt); a prompt's content goes to every other present client,
\* and a steer's to every present client.
SendIdle(r, k) ==
  /\ Present(r[1])
  /\ ~Refused(r[1])
  /\ turn = NoReq
  /\ status[r] = "unsent"
  /\ status' = [status EXCEPT ![r] = "turn"]
  /\ kindOf' = [kindOf EXCEPT ![r] = k]
  /\ turn' = r
  /\ turnStart' = StartPrompt
  /\ turnSys' = StartPrompt
  /\ atStart' = sysNow
  /\ chunkTo' = [chunkTo EXCEPT ![r] = IF k = "steer" THEN PresentSet ELSE EchoTo(r)]
  /\ echoBroken' = echoBroken \/ ((k # "steer") /\ (EchoTo(r) # PresentSet \ {r[1]}))
  /\ UNCHANGED <<fstate, queue, sysNow, sysBefore, cancelPending, cancelIgnored,
                 endReason, lastEnded, misrouted, twice, orderBroken, leftRan>>

\* server.zig: writePromptInProgress answers a prompt without delivery that
\* finds a turn running, with -32600. A refused follower's prompt, steer or
\* queued prompt is answered the same way, because fx won't take it.
SendRefused(r, k) ==
  /\ Present(r[1])
  /\ status[r] = "unsent"
  /\ (Refused(r[1]) \/ (turn # NoReq /\ k = "none"))
  /\ status' = [status EXCEPT ![r] = "refused"]
  /\ kindOf' = [kindOf EXCEPT ![r] = k]
  /\ twice' = (twice \/ Answered(r))
  /\ misrouted' = (misrouted \/ (Recipient(r) # r[1]))
  /\ UNCHANGED <<fstate, queue, turn, turnStart, turnSys, sysNow, sysBefore, atStart,
                 chunkTo, cancelPending, cancelIgnored, endReason, lastEnded,
                 echoBroken, orderBroken, leftRan>>

\* server.zig: promptFromFollower and decideSessionPrompt. A steer that finds
\* a turn running waits for the turn's next safe point, which Absorb takes.
SendSteer(r) ==
  /\ Present(r[1])
  /\ ~Refused(r[1])
  /\ turn # NoReq
  /\ status[r] = "unsent"
  /\ status' = [status EXCEPT ![r] = "pending"]
  /\ kindOf' = [kindOf EXCEPT ![r] = "steer"]
  /\ UNCHANGED <<fstate, queue, turn, turnStart, turnSys, sysNow, sysBefore, atStart,
                 chunkTo, cancelPending, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken, leftRan>>

\* server.zig: decideSessionPrompt queues a prompt that finds a turn running.
\* It runs after the turn before it, in the order it arrived (Advance).
SendQueue(r) ==
  /\ Present(r[1])
  /\ ~Refused(r[1])
  /\ turn # NoReq
  /\ status[r] = "unsent"
  /\ status' = [status EXCEPT ![r] = "queued"]
  /\ kindOf' = [kindOf EXCEPT ![r] = "queue"]
  /\ queue' = Append(queue, r)
  /\ UNCHANGED <<fstate, turn, turnStart, turnSys, sysNow, sysBefore, atStart,
                 chunkTo, cancelPending, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken, leftRan>>

\* server.zig: takeSteering hands the running turn the steers that wait.
\* publishSteeringReplay (prompt.zig) sends each taken steer's chunk to every
\* present client, the sender included (sh-fx.md, Following a session, Prompts
\* from other clients: "every client gets its chunk, the sender included").
Absorb ==
  /\ turn # NoReq
  /\ Pending # {}
  /\ status' = [r \in Req |-> IF status[r] = "pending" THEN "absorbed" ELSE status[r]]
  /\ chunkTo' = [r \in Req |-> IF status[r] = "pending" THEN PresentSet ELSE chunkTo[r]]
  /\ leftRan' = leftRan \/ (\E r \in Req : (status[r] = "pending" /\ ~Present(r[1])))
  /\ UNCHANGED <<fstate, kindOf, queue, turn, turnStart, turnSys, sysNow, sysBefore,
                 atStart, cancelPending, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken>>

\* server.zig: startNextTurn starts the next queued prompt, and answerSender
\* answers each sender that is still present. A prompt or steer that the turn
\* took is answered when the turn ends, with the turn's reason: end_turn gives
\* status done, cancelled gives status stopped (the answer carries stopReason
\* cancelled). libfx_steering.zig: finishTurn ends the turn once no steer waits
\* for it. Each caller names its reason: Finish gives end_turn, and StopTurn
\* gives cancelled.
Advance(reason) ==
  LET P == Pending
      Done == {turn} \cup {r \in Req : status[r] = "absorbed"}
      Pick == CHOOSE s \in P : TRUE
      Next1 == NextQueued
      steerNext == P # {}
      queueNext == (~steerNext) /\ (queue # <<>>)
      endStatus == IF reason = "cancelled" THEN "stopped" ELSE "done"
  IN
  /\ status' = [r \in Req |->
        IF r \in Done THEN endStatus
        ELSE IF (steerNext /\ r = Pick) \/ (queueNext /\ r = Next1) THEN "turn"
        ELSE status[r]]
  /\ turn' = IF steerNext THEN Pick ELSE IF queueNext THEN Next1 ELSE NoReq
  /\ queue' = IF queueNext THEN RestQueued ELSE queue
  /\ turnStart' = StartPrompt
  /\ turnSys' = StartPrompt
  /\ atStart' = sysNow
  /\ chunkTo' = [r \in Req |->
        IF steerNext /\ r = Pick THEN PresentSet
        ELSE IF queueNext /\ r = Next1 THEN EchoTo(r)
        ELSE chunkTo[r]]
  /\ echoBroken' = (echoBroken \/ (queueNext /\ (EchoTo(Next1) # PresentSet \ {Next1[1]})))
  /\ twice' = (twice \/ (\E r \in Req : (r \in Done) /\ Present(r[1]) /\ Answered(r)))
  /\ misrouted' = (misrouted \/ (\E r \in Req : (r \in Done) /\ Present(r[1]) /\ (Recipient(r) # r[1])))
  /\ orderBroken' = (orderBroken \/ (queueNext /\ (Next1 # queue[1])))
  /\ leftRan' = (leftRan \/ (steerNext /\ ~Present(Pick[1])) \/ (queueNext /\ ~Present(Next1[1])))
  /\ endReason' = reason
  /\ lastEnded' = turn

\* server.zig: startNextTurn and libfx_steering.zig: finishTurn. The turn ends
\* normally once no steer waits for it.
Finish ==
  /\ turn # NoReq
  /\ Pending = {}
  /\ Advance("end_turn")
  /\ UNCHANGED <<fstate, kindOf, sysNow, sysBefore, cancelPending, cancelIgnored>>

\* server.zig: handleCancel (line 5569), reached from the session/cancel
\* dispatch. A cancel from a client the turn may obey stops the running turn:
\* the turn ends cancelled, and the steers and queued prompts that the turn did
\* not take run after it. sh-fx.md, Following a session, Stopping a turn (line
\* 267): "session/cancel names a session, so any client that has the session
\* open can stop the running turn, whichever client sent its prompt."
StopTurn(c) ==
  /\ cancelPending[c]
  /\ turn # NoReq
  /\ MayCancel(c)
  /\ cancelPending' = [cancelPending EXCEPT ![c] = FALSE]
  /\ Advance("cancelled")
  /\ UNCHANGED <<fstate, kindOf, sysNow, sysBefore, cancelIgnored>>

\* server.zig: handleCancel, for a cancel that this client may not send while
\* the turn runs (Rules FALSE: a joined client's session/cancel is refused,
\* sh-fx.md line 189). The cancel is handled and the turn goes on; cancelIgnored
\* records it, so AnyClientCancels fails.
IgnoreCancel(c) ==
  /\ cancelPending[c]
  /\ turn # NoReq
  /\ ~MayCancel(c)
  /\ cancelPending' = [cancelPending EXCEPT ![c] = FALSE]
  /\ cancelIgnored' = TRUE
  /\ UNCHANGED <<fstate, status, kindOf, queue, turn, turnStart, turnSys, sysNow,
                 sysBefore, atStart, chunkTo, endReason, lastEnded, misrouted,
                 twice, echoBroken, orderBroken, leftRan>>

\* server.zig: handleCancel with no turn running. The cancel has nothing to stop
\* and is cleared.
ClearIdleCancel(c) ==
  /\ cancelPending[c]
  /\ turn = NoReq
  /\ cancelPending' = [cancelPending EXCEPT ![c] = FALSE]
  /\ UNCHANGED <<fstate, status, kindOf, queue, turn, turnStart, turnSys, sysNow,
                 sysBefore, atStart, chunkTo, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken, leftRan>>

HandleCancel(c) == StopTurn(c) \/ IgnoreCancel(c) \/ ClearIdleCancel(c)

\* server.zig: the session/cancel dispatch (line 2825). A client sends
\* session/cancel while a turn runs. The request waits in cancelPending until
\* handleCancel runs.
RequestCancel(c) ==
  /\ Present(c)
  /\ turn # NoReq
  /\ ~cancelPending[c]
  /\ cancelPending' = [cancelPending EXCEPT ![c] = TRUE]
  /\ UNCHANGED <<fstate, status, kindOf, queue, turn, turnStart, turnSys, sysNow,
                 sysBefore, atStart, chunkTo, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken, leftRan>>

\* sessions.zig: followSharedSession joins the follower, and joinSession sends
\* it the replay and the answer. The join changes no input.
Join ==
  /\ fstate = "absent"
  /\ fstate' = "present"
  /\ UNCHANGED <<status, kindOf, queue, turn, turnStart, turnSys, sysNow, sysBefore,
                 atStart, chunkTo, cancelPending, cancelIgnored, endReason, lastEnded,
                 misrouted, twice, echoBroken, orderBroken, leftRan>>

\* sessions.zig: commitClientSystemPrompt, reached from followSharedSession and
\* reuseOpenSession. A load with a system prompt that differs replaces the
\* session's prompt from the next turn, and a running turn keeps the prompt it
\* started with (turnSys does not change here). Rules FALSE ignores the
\* follower's prompt.
Load ==
  /\ fstate = "present"
  /\ IF Rules THEN sysNow' \in Sys ELSE sysNow' = sysNow
  /\ sysBefore' = sysNow
  /\ turnSys' = turnSys
  /\ UNCHANGED <<fstate, status, kindOf, queue, turn, turnStart, atStart, chunkTo,
                 cancelPending, cancelIgnored, endReason, lastEnded, misrouted,
                 twice, echoBroken, orderBroken, leftRan>>

\* server.zig: withdrawFollowerInput, reached from detachFollower. When F
\* leaves, its queued prompts and its waiting steers are dropped. When it
\* closes, each one is answered with -32800 (status cancelled); when it
\* disconnects, none is answered (status withdrawn). "session/close answers each
\* steer and queued prompt that hasn't run with -32800" (sh-fx.md, Steering and
\* queued prompts).
LeaveWith(answering) ==
  /\ fstate = "present"
  /\ fstate' = "gone"
  /\ queue' = Without(queue, Follower)
  /\ status' = [r \in Req |->
        IF (r[1] = Follower) /\ ((status[r] = "queued") \/ (status[r] = "pending"))
        THEN (IF answering THEN "cancelled" ELSE "withdrawn")
        ELSE status[r]]
  /\ cancelPending' = [cancelPending EXCEPT ![Follower] = FALSE]
  /\ UNCHANGED <<kindOf, turn, turnStart, turnSys, sysNow, sysBefore, atStart, chunkTo,
                 cancelIgnored, endReason, lastEnded, misrouted, twice, echoBroken,
                 orderBroken, leftRan>>

Close == LeaveWith(TRUE)
Disconnect == LeaveWith(FALSE)

Next ==
  \/ Join
  \/ Load
  \/ Close
  \/ Disconnect
  \/ Absorb
  \/ Finish
  \/ \E c \in Clients : (RequestCancel(c) \/ HandleCancel(c))
  \/ \E r \in Req, k \in Kinds : (SendIdle(r, k) \/ SendRefused(r, k))
  \/ \E r \in Req : (SendSteer(r) \/ SendQueue(r))

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ WF_vars(Absorb)
  /\ WF_vars(Finish)
  /\ WF_vars(HandleCancel(Owner))
  /\ WF_vars(HandleCancel(Follower))

TypeOK ==
  /\ fstate \in {"absent", "present", "gone"}
  /\ status \in [Req -> {"unsent", "refused", "queued", "pending", "turn", "absorbed",
                         "done", "stopped", "cancelled", "withdrawn"}]
  /\ kindOf \in [Req -> Kinds]
  /\ queue \in Seq(Req)
  /\ turn \in Req \cup {NoReq}
  /\ turnStart \in Sys
  /\ turnSys \in Sys
  /\ sysNow \in Sys
  /\ sysBefore \in Sys
  /\ atStart \in Sys
  /\ chunkTo \in [Req -> SUBSET Clients]
  /\ cancelPending \in [Clients -> BOOLEAN]
  /\ cancelIgnored \in BOOLEAN
  /\ endReason \in EndReasons
  /\ lastEnded \in Req \cup {NoReq}
  /\ misrouted \in BOOLEAN
  /\ twice \in BOOLEAN
  /\ echoBroken \in BOOLEAN
  /\ orderBroken \in BOOLEAN
  /\ leftRan \in BOOLEAN

\* sh-fx.md, Following a session, line 201: "fx keeps one order for the input of
\* all clients." Steering and queued prompts, line 157: "fx starts each queued
\* prompt as a turn of its own when the turn before it ends, in the order it
\* received them." A queued prompt never starts before one that arrived
\* earlier, whichever client sent it.
OneOrder == ~orderBroken

\* sh-fx.md, Following a session, line 201 (every client may send prompts), and
\* Steering and queued prompts, lines 146 and 157: "The response to a steer
\* arrives when the turn that took it ends" and "The response to a queued prompt
\* is the response of its own turn". Every answer goes to its request's sender,
\* and each request is answered at most once.
AnswerToSender == (~misrouted) /\ (~twice)

\* sh-fx.md, Following a session, Prompts from other clients (line 257): "When a
\* prompt starts a turn, or runs after the queue, fx sends its content as
\* `user_message_chunk` updates to every other client that has the session open,"
\* and "the sender gets no copy". Each present client other than the sender gets
\* the chunk when the prompt starts (echoBroken), and the sender never does.
EchoExceptSender ==
  (~echoBroken) /\ (\A r \in Req : (kindOf[r] # "steer") => (r[1] \notin chunkTo[r]))

\* sh-fx.md, Following a session, Prompts from other clients (line 257): "A steer
\* is different: when the turn takes it, every client gets its chunk, the sender
\* included." A taken steer's chunk reaches its sender.
SteerChunkEveryone ==
  \A r \in Req :
    ((kindOf[r] = "steer") /\ (status[r] \in {"turn", "absorbed", "done", "stopped"}))
      => (r[1] \in chunkTo[r])

\* sh-fx.md, Steering and queued prompts, lines 162-163: "A client withdraws a
\* steer or a queued prompt that hasn't run yet" with $/cancel_request, and
\* "session/close answers each steer and queued prompt that hasn't run with
\* -32800". Those rules remove a leaving follower's waiting input, so no prompt
\* from a client that has left starts a turn after it left (sh-fx.md,
\* Following a session, line 203: "A connection that closes acts the same way").
LeftInputNeverRuns == ~leftRan

\* sh-fx.md, Following a session, line 199: "a prompt that differs from the
\* session's replaces it from the next turn, for every client." The first half:
\* a running turn keeps the system prompt it started with (turnSys = turnStart).
SystemPromptFromNextTurn == (turn # NoReq) => (turnSys = turnStart)

\* sh-fx.md, Following a session, line 199, second half: a turn that starts after
\* a load with a new prompt uses that prompt. atStart records the session's
\* prompt when the running turn started; the turn must send that prompt.
NewTurnUsesCurrentPrompt == (turn # NoReq) => (turnSys = atStart)

\* sh-fx.md, Following a session, Stopping a turn (line 267): "Every client then
\* sees the turn end, and the prompt's sender gets its response with `stopReason`
\* `cancelled`." Two parts. No cancel from a client that may send one is ignored
\* (cancelIgnored). And the last ended turn's sender, if still present, has the
\* answer that its end reason gives: stopped for cancelled, done for end_turn.
\* StopTurn gives the cancelled end, so the first part holds by construction of
\* the actions; the check guards that construction and the answer.
AnyClientCancels ==
  (~cancelIgnored) /\
  (IF (lastEnded = NoReq) \/ (~Present(lastEnded[1])) THEN TRUE
   ELSE status[lastEnded] = (IF endReason = "cancelled" THEN "stopped" ELSE "done"))

\* sh-fx.md, Following a session, line 201: "Every client of a session may send
\* prompts." Every prompt from a client that is still present gets an answer. A
\* steer or queued prompt gets its answer when its turn ends (Steering and queued
\* prompts).
WaitingInputAnswered ==
  \A r \in Req :
    [](((status[r] # "unsent") /\ (~Answered(r)))
         => <>(Answered(r) \/ ~Present(r[1])))

\* sh-fx.md, Following a session, line 201, and line 189 for the older behavior
\* under Rules FALSE: "A joined client can't change the session yet". A steer or
\* queued prompt that a present follower sends is taken by a turn, or the
\* follower leaves first.
FollowerPromptRuns ==
  \A r \in Req :
    [](((Wanted(r) /\ ~Taken(r)) /\ (fstate = "present"))
         => <>(Taken(r) \/ (fstate # "present")))

=============================================================================
