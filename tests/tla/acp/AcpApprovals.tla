---------------------------- MODULE AcpApprovals ----------------------------
(***************************************************************************)
(* Approvals across the clients of one session in fx acp: the permission   *)
(* request of a turn goes to every client that has the session open, the  *)
(* first valid answer decides, and the other clients are told. This is   *)
(* the "Permission requests" part of src/protocol/spec/sh-fx.md, as the   *)
(* approvals change builds it in src/acp/. AcpSharedSession.tla checks    *)
(* the message channels of the same part; this module checks who holds    *)
(* the request, which id each client was given, and who may decide.       *)
(*                                                                         *)
(* Clients: Conns. Opener is the client that opened the session. A turn   *)
(* starts from a client's prompt and is its sender. Any open client may   *)
(* stop the running turn, answer the question with any id and any option  *)
(* (an adversarial client), join, or leave.                               *)
(*                                                                         *)
(* Designs, selected by the constant Design:                              *)
(*  - "current": today's code. The question goes to the main client only  *)
(*    (the oldest member), and a leaving main client's question moves to  *)
(*    the next one, which is asked again with a new id.                   *)
(*  - "A": the question goes to every member. Each client gets its own id  *)
(*    from its own counter. The first valid answer decides, and the other *)
(*    clients are told with a cancel. A leaving client's entry is dropped, *)
(*    and nobody is asked again.                                          *)
(*  - "B": as A, but one id per session, shared with host tool requests,  *)
(*    so every client gets the same id.                                   *)
(*                                                                         *)
(* Writes: in "A" and "B" the fan-out is not one step. The target list is *)
(* taken under the lock, and each request, and each cancel, is written     *)
(* after it (WriteRequest, WriteCancel). A request is written only if the   *)
(* question is still undecided, so a late request never follows a decision *)
(* without its cancel. In "current" the one write is atomic.              *)
(*                                                                         *)
(* Planted bugs (Mutant): alwaysAnyone, secondAnswer, noCancel, reask,     *)
(* joinerMisses, noDenyLast, anyId, writeAfter, followerDropped, and       *)
(* hostCollide (design B only, with host requests from a per-client       *)
(* counter). Each one breaks the invariant or property named in check.sh. *)
(*                                                                         *)
(* Not modelled: time and deadlines (so the cost of a stuck client is not  *)
(* measured), lock blocking (the writes are separate steps here), steers, queued *)
(* prompts, the sixteen-client cap (three clients are modelled), grants,   *)
(* the review of an action, and subagents.                                 *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Conns,        \* the client connections
    Opener,       \* the connection that opened the session; first in join order
    Design,       \* "current", "A", or "B"
    Mutant,       \* "none", or one planted bug
    MaxJoins,     \* joins in the whole run
    MaxLeaves,    \* leaves in the whole run
    MaxAsks,      \* permission questions in the whole run
    MaxPrompts,   \* turns in the whole run
    MaxId         \* the largest id a counter gives, and the largest answer id tried

None == "none"
Opts == {"once", "always", "reject", "cancelled", "junk"}

VARIABLES
    open,          \* [Conns -> BOOLEAN]: the client has the session open
    order,         \* the open clients, in join order; the main client is the head
    joins, leaves, \* counts, for the bounds
    turn,          \* the connection whose prompt runs, or None
    prompts, asks,
    hostId,        \* the id of the host tool request to the main client; 0 is none
    nextId,        \* [Conns -> Nat]: the per-client id counter
    sid,           \* the per-session id counter (design "B")
    qOpen,         \* a question is open (not yet cleaned up)
    qId,           \* the question's id in design "B"
    qSender,       \* the connection whose prompt asked the question
    qDecided,      \* the question has a decision
    qDecision,     \* "none", "once", "always", or "deny"
    qWinner,       \* the connection whose answer decided, or None
    qWinId,        \* the id of that answer
    targets,       \* the clients the question is registered to
    tid,           \* [Conns -> Nat]: the id the question has for the client
    sent,          \* [Conns -> BOOLEAN]: the request was written to the client
    wantSend,      \* clients whose request is waiting to be written
    wantCancel,    \* clients whose cancel is waiting to be written
    cancelled,     \* [Conns -> BOOLEAN]: the cancel was written to the client
    reasked,       \* a client was asked again because another left
    refusedValid   \* an answer that met the rules was refused

vars == <<open, order, joins, leaves, turn, prompts, asks, hostId, nextId, sid,
          qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
          targets, tid, sent, wantSend, wantCancel, cancelled, reasked, refusedValid>>

M(name) == Mutant = name

Main == IF order = <<>> THEN None ELSE Head(order)
Live == {c \in Conns : open[c]}
Room == sid < MaxId /\ \A c \in Conns : nextId[c] < MaxId

\* The options a client may choose. Only the sender may pick "always".
SpecOffered(c) ==
    IF Design = "current"
    THEN IF c = Main THEN {"once", "always", "reject", "cancelled"} ELSE {}
    ELSE {"once", "reject", "cancelled"} \cup (IF c = qSender THEN {"always"} ELSE {})

Offered(c) ==
    IF M("alwaysAnyone") /\ Design # "current" THEN SpecOffered(c) \cup {"always"}
    ELSE SpecOffered(c)

DecisionOf(opt) == IF opt = "always" THEN "always" ELSE IF opt = "once" THEN "once" ELSE "deny"

\* An answer the rules accept: the question is open and undecided, the client
\* is a target and was written its request, the id is its own, and the option
\* is one it was offered.
Valid(c, id, opt) ==
    /\ qOpen /\ ~qDecided /\ open[c] /\ c \in targets /\ sent[c]
    /\ id = tid[c] /\ opt \in SpecOffered(c)

Accept(c, id, opt) ==
    /\ qOpen /\ open[c] /\ c \in targets /\ sent[c]
    /\ (M("anyId") \/ id = tid[c])
    /\ opt \in Offered(c)
    /\ (M("secondAnswer") \/ ~qDecided)
    /\ ~(M("followerDropped") /\ c # Main)

Init ==
    /\ open = [c \in Conns |-> c = Opener]
    /\ order = <<Opener>>
    /\ joins = 0 /\ leaves = 0
    /\ turn = None /\ prompts = 0 /\ asks = 0
    /\ hostId = 0
    /\ nextId = [c \in Conns |-> 1]
    /\ sid = 1
    /\ qOpen = FALSE /\ qId = 0 /\ qSender = None
    /\ qDecided = FALSE /\ qDecision = "none" /\ qWinner = None /\ qWinId = 0
    /\ targets = {} /\ tid = [c \in Conns |-> 0] /\ sent = [c \in Conns |-> FALSE]
    /\ wantSend = {} /\ wantCancel = {} /\ cancelled = [c \in Conns |-> FALSE]
    /\ reasked = FALSE /\ refusedValid = FALSE

\* A client's prompt starts a turn.
Prompt(c) ==
    /\ open[c] /\ turn = None /\ prompts < MaxPrompts
    /\ turn' = c /\ prompts' = prompts + 1
    /\ UNCHANGED <<open, order, joins, leaves, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, sent, wantSend, wantCancel, cancelled, reasked, refusedValid>>

\* The turn asks for a permission. Today the question is written to the main
\* client at once. Otherwise every open client is registered, and its request
\* is written later. With no client open, the question is denied at once.
AskTargets == IF Design = "current" THEN (IF Main = None THEN {} ELSE {Main}) ELSE Live

Ask ==
    /\ turn # None /\ ~qOpen /\ asks < MaxAsks /\ Room
    /\ LET T == AskTargets IN
       /\ asks' = asks + 1
       /\ qOpen' = TRUE
       /\ qSender' = turn
       /\ qDecided' = (T = {})
       /\ qDecision' = IF T = {} THEN "deny" ELSE "none"
       /\ qWinner' = None
       /\ qWinId' = 0
       /\ qId' = IF Design = "B" THEN sid ELSE 0
       /\ targets' = T
       /\ tid' = [d \in Conns |-> IF d \in T THEN (IF Design = "B" THEN sid ELSE nextId[d]) ELSE tid[d]]
       /\ nextId' = [d \in Conns |-> IF d \in T /\ Design # "B" THEN nextId[d] + 1 ELSE nextId[d]]
       /\ sid' = IF Design = "B" /\ T # {} THEN sid + 1 ELSE sid
       /\ sent' = [d \in Conns |-> IF Design = "current" /\ d \in T THEN TRUE ELSE FALSE]
       /\ wantSend' = IF Design = "current" THEN {} ELSE T
       /\ wantCancel' = {}
       /\ cancelled' = [d \in Conns |-> FALSE]
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, hostId, reasked, refusedValid>>

\* The fan-out, written outside the lock. A request is written only while the
\* question is undecided (the write checks it), so a request never follows a
\* decision without its cancel.
WriteRequest(c) ==
    /\ c \in wantSend
    /\ wantSend' = wantSend \ {c}
    /\ IF (qDecided /\ ~M("writeAfter")) \/ ~open[c]
       THEN UNCHANGED sent
       ELSE sent' = [sent EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, wantCancel, cancelled, reasked, refusedValid>>

\* The cancel of a question that was decided, written outside the lock.
WriteCancel(c) ==
    /\ c \in wantCancel
    /\ wantCancel' = wantCancel \ {c}
    /\ cancelled' = [cancelled EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, sent, wantSend, reasked, refusedValid>>

\* A client answers the question with an id and an option. The first valid answer
\* decides, and the other clients that were sent the request are told to cancel it.
\* An answer that meets the rules but is refused is recorded, so a property can
\* see it.
Answer(c, id, opt) ==
    /\ IF Accept(c, id, opt)
       THEN /\ qDecided' = TRUE
            /\ qDecision' = DecisionOf(opt)
            /\ qWinner' = c
            /\ qWinId' = id
            /\ wantCancel' = IF M("noCancel") THEN wantCancel
                             ELSE wantCancel \cup {d \in Conns : d # c /\ d \in targets /\ sent[d] /\ ~cancelled[d]}
            /\ refusedValid' = refusedValid
       ELSE /\ refusedValid' = (refusedValid \/ Valid(c, id, opt))
            /\ UNCHANGED <<qDecided, qDecision, qWinner, qWinId, wantCancel>>
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, targets, tid, sent, wantSend, cancelled, reasked>>

\* session/cancel from an open client stops the turn. A question still open is
\* decided as denied, and the cancel goes to every client that has the request.
Cancel(c) ==
    /\ open[c] /\ turn # None
    /\ turn' = None
    /\ IF qOpen /\ ~qDecided
       THEN /\ qDecided' = TRUE
            /\ qDecision' = "deny"
            /\ qWinner' = None
            /\ wantCancel' = IF M("noCancel") THEN wantCancel
                             ELSE wantCancel \cup {d \in Conns : d \in targets /\ sent[d] /\ ~cancelled[d]}
       ELSE /\ UNCHANGED <<qDecided, qDecision, qWinner, wantCancel>>
    /\ UNCHANGED <<open, order, joins, leaves, prompts, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, qWinId, targets, tid, sent, wantSend, cancelled, reasked, refusedValid>>

\* A client joins the session. A question still open is registered to it after
\* its replay, so its request is written next, and the join holds the lock.
Join(c) ==
    /\ ~open[c] /\ joins < MaxJoins
    /\ open' = [open EXCEPT ![c] = TRUE]
    /\ order' = Append(order, c)
    /\ joins' = joins + 1
    /\ LET reg == qOpen /\ ~qDecided /\ Design # "current" /\ ~M("joinerMisses") IN
       /\ targets' = IF reg THEN targets \cup {c} ELSE targets
       /\ tid' = IF reg THEN [tid EXCEPT ![c] = IF Design = "B" THEN qId ELSE nextId[c]] ELSE tid
       /\ nextId' = IF reg /\ Design # "B" THEN [nextId EXCEPT ![c] = nextId[c] + 1] ELSE nextId
       /\ wantSend' = IF reg THEN wantSend \cup {c} ELSE wantSend
       /\ sent' = IF reg THEN [sent EXCEPT ![c] = FALSE] ELSE sent
    /\ UNCHANGED <<leaves, turn, prompts, asks, hostId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   wantCancel, cancelled, reasked, refusedValid>>

\* A client leaves (session/close, or its input ends). Its entries are dropped.
\* Nobody is asked again, and the question is denied when no client is left.
\* In "current" the main client's question moves to the next client, which is
\* asked again with a new id.
Leave(c) ==
    /\ open[c] /\ leaves < MaxLeaves
    /\ LET newOrder == SelectSeq(order, LAMBDA x : x # c)
           newTargets == targets \ {c}
           newMain == IF newOrder = <<>> THEN None ELSE Head(newOrder)
           pending == qOpen /\ ~qDecided
           reaskCur == pending /\ Design = "current" /\ c = Main /\ newOrder # <<>>
           reaskMut == pending /\ M("reask") /\ Design = "A" /\ c \in targets /\ newTargets # {}
           reask == reaskCur \/ reaskMut
           deny == pending /\ ~reask /\ newTargets = {} /\ ~M("noDenyLast")
       IN
       /\ open' = [open EXCEPT ![c] = FALSE]
       /\ order' = newOrder
       /\ leaves' = leaves + 1
       /\ targets' = IF reaskCur THEN {newMain} ELSE newTargets
       /\ tid' = IF reask THEN [tid EXCEPT ![newMain] = nextId[newMain]] ELSE tid
       /\ nextId' = IF reask THEN [nextId EXCEPT ![newMain] = nextId[newMain] + 1] ELSE nextId
       /\ sent' = IF reask THEN [sent EXCEPT ![newMain] = TRUE] ELSE sent
       /\ wantSend' = wantSend \ {c}
       /\ wantCancel' = wantCancel \ {c}
       /\ hostId' = IF c = Main THEN 0 ELSE hostId
       /\ qDecided' = IF deny THEN TRUE ELSE qDecided
       /\ qDecision' = IF deny THEN "deny" ELSE qDecision
       /\ qWinner' = IF deny THEN None ELSE qWinner
       /\ reasked' = IF reask THEN TRUE ELSE reasked
    /\ UNCHANGED <<joins, turn, prompts, asks, sid, qOpen, qId, qSender, qWinId, cancelled, refusedValid>>

\* The waiting turn takes the decision and clears the question once every cancel
\* has been written. Writes still waiting for a decided question are dropped.
Clear ==
    /\ qOpen /\ qDecided /\ wantCancel = {}
    /\ qOpen' = FALSE
    /\ targets' = {}
    /\ sent' = [d \in Conns |-> FALSE]
    /\ wantSend' = {}
    /\ cancelled' = [d \in Conns |-> FALSE]
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks, hostId, nextId, sid,
                   qId, qSender, qDecided, qDecision, qWinner, qWinId, tid, wantCancel,
                   reasked, refusedValid>>

\* The turn ends once no question is open and no host tool request is pending.
EndTurn ==
    /\ turn # None /\ ~qOpen /\ hostId = 0
    /\ turn' = None
    /\ UNCHANGED <<open, order, joins, leaves, prompts, asks, hostId, nextId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, sent, wantSend, wantCancel, cancelled, reasked, refusedValid>>

\* A host tool request goes to the main client. Its id comes from the session
\* counter in "B", and from the client's counter otherwise. The planted bug
\* "hostCollide" gives "B" the client counter, which collides with the question.
HostRequest ==
    /\ turn # None /\ hostId = 0 /\ Main # None /\ Room
    /\ IF Design = "B" /\ ~M("hostCollide")
       THEN /\ hostId' = sid /\ sid' = sid + 1 /\ nextId' = nextId
       ELSE /\ hostId' = nextId[Main]
            /\ nextId' = [nextId EXCEPT ![Main] = nextId[Main] + 1]
            /\ sid' = sid
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, sent, wantSend, wantCancel, cancelled, reasked, refusedValid>>

HostAnswer(c, id) ==
    /\ hostId # 0 /\ c = Main /\ id = hostId
    /\ hostId' = 0
    /\ UNCHANGED <<open, order, joins, leaves, turn, prompts, asks, nextId, sid,
                   qOpen, qId, qSender, qDecided, qDecision, qWinner, qWinId,
                   targets, tid, sent, wantSend, wantCancel, cancelled, reasked, refusedValid>>

Next ==
    \/ \E c \in Conns :
          Join(c) \/ Leave(c) \/ Prompt(c) \/ Cancel(c) \/ WriteRequest(c) \/ WriteCancel(c)
    \/ \E c \in Conns, id \in 1..MaxId, opt \in Opts : Answer(c, id, opt)
    \/ \E c \in Conns, id \in 1..MaxId : HostAnswer(c, id)
    \/ Ask \/ Clear \/ EndTurn \/ HostRequest

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants and properties *)

\* Every open client is registered to a question that is still open and undecided.
EveryClientGetsQuestion ==
    (qOpen /\ ~qDecided) => \A c \in Conns : open[c] => c \in targets

\* A question that is still open and undecided has a client to answer it.
DeniedWhenNoClient ==
    (qOpen /\ ~qDecided) => \E c \in Conns : open[c]

\* "Allow for this session" is decided only by the client that sent the prompt.
OnlySenderAlways ==
    (qOpen /\ qDecided /\ qDecision = "always") => qWinner = qSender

\* The decision came from an answer to the id that was given to the winner, and
\* that client was written the request.
WinnerHadRequest ==
    (qOpen /\ qDecided /\ qWinner # None) => (sent[qWinner] /\ qWinId = tid[qWinner])

\* Every other client that was written the request is told the question is over.
OthersTold ==
    (qOpen /\ qDecided) =>
        \A c \in Conns :
            (c \in targets /\ sent[c] /\ c # qWinner) => (cancelled[c] \/ c \in wantCancel)

\* A client is never asked again for the same question.
NoReAsk == ~reasked

\* An answer that meets the rules is never refused.
ValidAnswerNotRefused == ~refusedValid

\* A client's request id and its host tool request id never match.
IdsDistinct ==
    IF Main \in Conns
    THEN (hostId = 0 \/ ~qOpen \/ ~(Main \in targets) \/ tid[Main] # hostId)
    ELSE TRUE

\* A turn with no question open is not waiting on a decision that never comes.
TurnEndClosesQuestion == (turn = None /\ qOpen) => qDecided

OrderMatchesOpen == \A c \in Conns : open[c] <=> (\E i \in 1..Len(order) : order[i] = c)

\* Witnesses: each must be violated, which shows the model reaches the state.
NoFollowerWin == ~(qOpen /\ qDecided /\ qWinner \in Conns /\ qWinner # Opener)
NoAlwaysWin == ~(qOpen /\ qDecided /\ qDecision = "always")

\* Once decided, a question keeps its decision until it is cleared.
DecisionStable ==
    [][(qOpen /\ qDecided /\ qOpen') => (qDecision' = qDecision /\ qWinner' = qWinner)]_vars

=============================================================================
