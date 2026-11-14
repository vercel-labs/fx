---- MODULE Request ----
\* U02 request lifecycle, client side and transport-agnostic.
\* Rules: WIRE-01, WIRE-06, WIRE-10, REQ-01..REQ-06, STDIO-04, LHTTP-08, SUBS-03.
\* It also models timeouts, errors without an id, ids that are never reused,
\* and subscriptions/listen, which has no timeout.
\*
\* Each id in Ids is one request the client may send; InitIds are the ones
\* sent as initialize (more than one after a 2025 session re-initializes, U07),
\* and ListenIds the subscriptions/listen requests (U10), which stay open until
\* answered, cancelled, or lost, and which a server may end with a
\* notifications/cancelled of its own (SUBS-03). The server can answer
\* any id at any time, any number of times, so late, duplicate, and unknown-id
\* responses are all part of the state space. A response with no id cannot be
\* correlated at all: it changes nothing here, and the request still ends
\* through its timeout. Time is abstract: TimedOut is the hard maximum, which
\* weak fairness guarantees eventually fires while a request stays in flight.
\* Progress values are integers here; the spec allows floats, compared the
\* same way.
\*
\* A line the client refused that names no request cannot be correlated: bytes
\* that are not UTF-8, JSON nested past the engine's limit with its id after
\* the bad part, or a line with no id at all. RefusedLine gives every normal
\* request in flight that has no grace one: a deadline GraceTicks away, which
\* never extends. A response inside the grace still matches. Progress for the
\* request's own token clears its grace, and its other timers go on. A request
\* still silent at the deadline ends as `malformed`, with a cancel signal.
\* initialize and listen get no grace, and neither does a request sent after the
\* line. A request has at most one grace, so the grace timers never outnumber
\* the requests in flight. Time is abstract unless Timed: then `now` counts
\* ticks, a request's own deadline is the end of the modelled time (one sooner than the
\* grace is for the Table's tests and the drivers), and time cannot pass a grace that is due. GraceOn = FALSE is the code before the grace:
\* a refused line changes nothing (Request.findings.cfg).
EXTENDS Naturals, FiniteSets

CONSTANTS Ids, InitIds, ListenIds, MaxProgress, Timed, GraceOn, GraceTicks, MaxTime, MaxRefusals

ASSUME InitIds \subseteq Ids /\ ListenIds \subseteq Ids \ InitIds /\ MaxProgress \in Nat
ASSUME Timed \in BOOLEAN /\ GraceOn \in BOOLEAN /\ GraceTicks \in Nat /\ MaxTime \in Nat /\ MaxRefusals \in Nat

Status == {"unused", "inflight", "done"}
Outcome == {"none", "result", "error", "cancelled", "timed_out", "lost", "ended", "malformed"}

\* "never" for a time, and "no refusal yet" for a count.
NoTime == MaxTime + GraceTicks + 1
NoEpoch == MaxRefusals + 1
Words == {"none", "malformed", "server_text"}
PeerKind == {"result", "error"}

VARIABLES
    req,           \* [Ids -> Status]
    outcome,       \* [Ids -> Outcome]: what the caller was given
    delivered,     \* [Ids -> Nat]: outcomes handed to the caller
    cancelSent,    \* [Ids -> BOOLEAN]: a cancel signal was sent for the request
    progress,      \* [Ids -> 0..MaxProgress]: last accepted progress value
    everDone,      \* ghost [Ids -> BOOLEAN]: the request has finished before
    peerAnswered,  \* ghost [Ids -> BOOLEAN]: a response arrived while in flight
    progressSeen,  \* ghost: <<id, status>> at each accepted progress notification
    now,           \* abstract time, in ticks (moves only when Timed)
    refusals,      \* refused lines seen
    sentEpoch,     \* ghost [Ids -> 0..MaxRefusals]: refusals seen when it was sent
    graceDue,      \* [Ids -> ticks, or NoTime]: the request's grace deadline
    armedEpoch,    \* ghost [Ids -> refusal number, or NoEpoch]: the refusal that gave it a grace
    graceTimers,   \* grace timers armed
    refusedAt,     \* ghost [Ids -> ticks, or NoTime]: when a refused line first found it in flight
    ownProgress,   \* ghost [Ids -> BOOLEAN]: progress accepted for it after such a line
    words          \* ghost [Ids -> Words]: how a request that the grace ended was worded

vars == <<req, outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen,
          now, refusals, sentEpoch, graceDue, armedEpoch, graceTimers, refusedAt, ownProgress, words>>

\* Everything the grace adds but its deadlines and timers.
Rest == <<now, refusals, sentEpoch, armedEpoch, refusedAt, ownProgress, words>>

Init ==
    /\ req = [id \in Ids |-> "unused"]
    /\ outcome = [id \in Ids |-> "none"]
    /\ delivered = [id \in Ids |-> 0]
    /\ cancelSent = [id \in Ids |-> FALSE]
    /\ progress = [id \in Ids |-> 0]
    /\ everDone = [id \in Ids |-> FALSE]
    /\ peerAnswered = [id \in Ids |-> FALSE]
    /\ progressSeen = {}
    /\ now = 0
    /\ refusals = 0
    /\ sentEpoch = [id \in Ids |-> 0]
    /\ graceDue = [id \in Ids |-> NoTime]
    /\ armedEpoch = [id \in Ids |-> NoEpoch]
    /\ graceTimers = 0
    /\ refusedAt = [id \in Ids |-> NoTime]
    /\ ownProgress = [id \in Ids |-> FALSE]
    /\ words = [id \in Ids |-> "none"]

Armed(id) == graceDue[id] # NoTime

\* A request that ends takes its grace with it.
Disarm(id) ==
    /\ graceDue' = [graceDue EXCEPT ![id] = NoTime]
    /\ graceTimers' = graceTimers - (IF Armed(id) THEN 1 ELSE 0)

\* Ends a request with outcome o and hands o to the caller.
Finish(id, o) ==
    /\ req' = [req EXCEPT ![id] = "done"]
    /\ outcome' = [outcome EXCEPT ![id] = o]
    /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
    /\ everDone' = [everDone EXCEPT ![id] = TRUE]
    /\ Disarm(id)

\* What a request gets for the refused lines before it was sent: nothing.
SendGrace(id) ==
    /\ graceDue' = [graceDue EXCEPT ![id] = NoTime]
    /\ armedEpoch' = armedEpoch
    /\ graceTimers' = graceTimers

\* The client sends a request with a fresh id (WIRE-01).
Send(id) ==
    /\ req[id] = "unused"
    /\ req' = [req EXCEPT ![id] = "inflight"]
    /\ sentEpoch' = [sentEpoch EXCEPT ![id] = refusals]
    /\ SendGrace(id)
    /\ UNCHANGED <<outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen, now, refusals, refusedAt, ownProgress, words>>

Accept(id, kind) ==
    /\ Finish(id, kind)
    /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<cancelSent, progress, progressSeen, Rest>>

\* A result or error response for id arrives. Only a request in flight takes
\* it; late, duplicate, and unknown-id responses are ignored (REQ-02).
ResponseReceived(id, kind) ==
    IF req[id] = "inflight" THEN Accept(id, kind) ELSE UNCHANGED vars

\* The caller cancels. The client never cancels initialize (REQ-06).
CancelRequested(id) ==
    /\ req[id] = "inflight"
    /\ id \notin InitIds
    /\ Finish(id, "cancelled")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen, Rest>>

\* A request's own deadline has come, or the modelled time is over.
IdleReady(id) == ~Timed \/ now >= MaxTime

\* The hard timeout fires (REQ-03). The outcome is a local error, never a
\* peer error (WIRE-10). Initialize times out without a cancel signal. A
\* listen has no timeout.
TimedOut(id) ==
    /\ req[id] = "inflight"
    /\ id \notin ListenIds
    /\ IdleReady(id)
    /\ Finish(id, "timed_out")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = ~(id \in InitIds)]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen, Rest>>

\* The transport fails before the response: a stream breaks or the server
\* process exits. Re-sending is a new request with a new id (U06).
TransportLost(id) ==
    /\ req[id] = "inflight"
    /\ Finish(id, "lost")
    /\ UNCHANGED <<cancelSent, progress, peerAnswered, progressSeen, Rest>>

\* Progress for a request's own token after a refused line shows its server is alive: its
\* grace is cleared and its other timers go on. Another request's progress does not.
ProgressClears(id) ==
    /\ ownProgress' = [ownProgress EXCEPT ![id] = ownProgress[id] \/ refusedAt[id] # NoTime]
    /\ Disarm(id)

\* A progress notification for id's token. It is accepted only while the
\* request is in flight and only when the value increases (REQ-04, WIRE-06).
ProgressReceived(id, p) ==
    IF req[id] = "inflight" /\ p > progress[id]
    THEN /\ progress' = [progress EXCEPT ![id] = p]
         /\ progressSeen' = progressSeen \cup {<<id, req[id]>>}
         /\ ProgressClears(id)
         /\ UNCHANGED <<req, outcome, delivered, cancelSent, everDone, peerAnswered, now, refusals, sentEpoch, armedEpoch, refusedAt, words>>
    ELSE UNCHANGED vars

\* The server sends notifications/cancelled naming a client request. That
\* ends a listen in flight: the server tore the subscription down (SUBS-03).
\* For any other request it is never valid, so it is ignored (REQ-05).
ServerCancelReceived(id) ==
    IF id \in ListenIds /\ req[id] = "inflight"
    THEN /\ Finish(id, "ended")
         /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
         /\ UNCHANGED <<cancelSent, progress, progressSeen, Rest>>
    ELSE UNCHANGED vars

\* The normal requests in flight, and those among them with no grace yet.
Pending == {id \in Ids \ (InitIds \cup ListenIds) : req[id] = "inflight"}
Fresh == {id \in Pending : graceDue[id] = NoTime}

\* A line the client refused that names no request. Each request that has no grace
\* gets one; a request that has one keeps its deadline, and one timer covers the
\* requests a line finds without.
RefusedLine ==
    /\ refusals < MaxRefusals
    /\ refusals' = refusals + 1
    \* A grace that starts now is a new window: the ghosts start over for the requests that get one.
    /\ refusedAt' = [id \in Ids |-> IF (GraceOn /\ id \in Fresh) \/ (id \in Pending /\ refusedAt[id] = NoTime) THEN now ELSE refusedAt[id]]
    /\ ownProgress' = [id \in Ids |-> IF GraceOn /\ id \in Fresh THEN FALSE ELSE ownProgress[id]]
    /\ IF GraceOn
       THEN /\ graceDue' = [id \in Ids |-> IF id \in Fresh THEN now + GraceTicks ELSE graceDue[id]]
            /\ armedEpoch' = [id \in Ids |-> IF id \in Fresh THEN refusals + 1 ELSE armedEpoch[id]]
            /\ graceTimers' = graceTimers + Cardinality(Fresh)
       ELSE UNCHANGED <<graceDue, armedEpoch, graceTimers>>
    /\ UNCHANGED <<req, outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen, now, sentEpoch, words>>

\* The grace of a request that stayed silent runs out: it ends as malformed, and
\* the server is told it was cancelled.
GraceExpired(id) ==
    /\ Armed(id)
    /\ (~Timed \/ graceDue[id] <= now)
    /\ req[id] = "inflight"
    /\ Finish(id, "malformed")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = TRUE]
    /\ words' = [words EXCEPT ![id] = "malformed"]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen, now, refusals, sentEpoch, armedEpoch, refusedAt, ownProgress>>

\* Time passes, but never past a grace that is due.
Tick ==
    /\ Timed
    /\ now < MaxTime
    /\ \A id \in Ids : (~Armed(id) \/ graceDue[id] > now)
    /\ now' = now + 1
    /\ UNCHANGED <<req, outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen, refusals, sentEpoch, graceDue, armedEpoch, graceTimers, refusedAt, ownProgress, words>>

Next ==
    \/ RefusedLine
    \/ Tick
    \/ \E id \in Ids:
        \/ Send(id)
        \/ \E kind \in PeerKind: ResponseReceived(id, kind)
        \/ CancelRequested(id)
        \/ TimedOut(id)
        \/ TransportLost(id)
        \/ \E p \in 1..MaxProgress: ProgressReceived(id, p)
        \/ ServerCancelReceived(id)
        \/ GraceExpired(id)

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ \A id \in Ids: (WF_vars(TimedOut(id)) /\ WF_vars(GraceExpired(id)))

TypeOK ==
    /\ req \in [Ids -> Status]
    /\ outcome \in [Ids -> Outcome]
    /\ delivered \in [Ids -> 0..2]
    /\ cancelSent \in [Ids -> BOOLEAN]
    /\ progress \in [Ids -> 0..MaxProgress]
    /\ everDone \in [Ids -> BOOLEAN]
    /\ peerAnswered \in [Ids -> BOOLEAN]
    /\ progressSeen \subseteq (Ids \X Status)
    /\ now \in 0..MaxTime
    /\ refusals \in 0..MaxRefusals
    /\ sentEpoch \in [Ids -> 0..MaxRefusals]
    /\ graceDue \in [Ids -> 0..NoTime]
    /\ armedEpoch \in [Ids -> 1..NoEpoch]
    /\ graceTimers \in 0..(Cardinality(Ids) + MaxRefusals)
    /\ refusedAt \in [Ids -> 0..NoTime]
    /\ ownProgress \in [Ids -> BOOLEAN]
    /\ words \in [Ids -> Words]

\* WIRE-01: a finished id never goes back in flight.
IdsNeverReused == \A id \in Ids: everDone[id] => req[id] = "done"

\* REQ-02: one outcome per request, even with late or duplicate responses.
AtMostOneOutcome == \A id \in Ids: delivered[id] <= 1

\* A finished request has delivered exactly one outcome; others none.
OutcomeIffDone == \A id \in Ids: (req[id] = "done") = (delivered[id] = 1 /\ outcome[id] # "none")

\* WIRE-10: a result, a peer error, or a server's end only ever comes from the peer.
PeerOutcomesFromPeer == \A id \in Ids: outcome[id] \in PeerKind \cup {"ended"} => peerAnswered[id]

\* A listen never times out.
ListenNeverTimesOut == \A id \in ListenIds: outcome[id] # "timed_out"

\* REQ-05, SUBS-03: only a listen is ever ended by the server.
EndedOnlyListen == \A id \in Ids: outcome[id] = "ended" => id \in ListenIds

\* REQ-05: a request ends as cancelled only because the client cancelled it.
CancelledByClientOnly == \A id \in Ids: outcome[id] = "cancelled" => cancelSent[id]

\* REQ-01: a cancel signal goes only to requests the client ended in flight.
CancelValid == \A id \in Ids: cancelSent[id] => outcome[id] \in {"cancelled", "timed_out", "malformed"}

\* REQ-06, LHTTP-08: initialize is never cancelled.
NeverCancelInitialize == \A id \in InitIds: ~cancelSent[id]

\* REQ-04, WIRE-06: progress is accepted only for requests in flight.
ProgressScoped == \A x \in progressSeen: x[2] = "inflight"

\* REQ-03: every request in flight but a listen eventually ends.
EveryRequestEnds == \A id \in Ids \ ListenIds: req[id] = "inflight" ~> req[id] = "done"

\* A grace belongs to a request in flight, and a finished one leaves none behind.
GraceOnlyInFlight == \A id \in Ids: Armed(id) => req[id] = "inflight"

\* The grace timers are exactly the graces, which are at most one per request, so a
\* flood of refused lines cannot make them grow.
TimersAreGraces == graceTimers = Cardinality({id \in Ids: Armed(id)})
TimersBounded == graceTimers <= Cardinality(Ids)

\* initialize and listen are never given a grace or ended by one.
NoGraceForInitOrListen == \A id \in InitIds \cup ListenIds: ~Armed(id) /\ outcome[id] # "malformed"

\* Only a request that had a grace ends as malformed.
MalformedOnlyIfGraced == \A id \in Ids: outcome[id] = "malformed" => armedEpoch[id] # NoEpoch

\* A request sent after a refused line gets no grace from it.
NoGraceForLaterCalls == \A id \in Ids: armedEpoch[id] # NoEpoch => armedEpoch[id] > sentEpoch[id]

\* A grace that is gone from a request in flight was cleared by that request's own progress.
GraceClearedOnlyByOwnProgress ==
    \A id \in Ids: (armedEpoch[id] # NoEpoch /\ req[id] = "inflight" /\ ~Armed(id)) => ownProgress[id]

\* A request whose server sent progress after the line is not ended by the grace.
ProgressProtects == \A id \in Ids: ownProgress[id] => outcome[id] # "malformed"

\* The words of an ended request never carry what the server wrote.
WordsFixed == \A id \in Ids: words[id] # "server_text"

\* A request that was in flight at a refused line, and stayed silent, ends within the
\* grace. This is what the code before the grace breaks (Request.findings.cfg).
SoonAfterRefusal ==
    \A id \in Ids: (req[id] = "inflight" /\ refusedAt[id] # NoTime /\ ~ownProgress[id])
        => now <= refusedAt[id] + GraceTicks
====
