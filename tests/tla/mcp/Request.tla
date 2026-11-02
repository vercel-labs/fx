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
EXTENDS Naturals, FiniteSets

CONSTANTS Ids, InitIds, ListenIds, MaxProgress

ASSUME InitIds \subseteq Ids /\ ListenIds \subseteq Ids \ InitIds /\ MaxProgress \in Nat

Status == {"unused", "inflight", "done"}
Outcome == {"none", "result", "error", "cancelled", "timed_out", "lost", "ended"}
PeerKind == {"result", "error"}

VARIABLES
    req,           \* [Ids -> Status]
    outcome,       \* [Ids -> Outcome]: what the caller was given
    delivered,     \* [Ids -> Nat]: outcomes handed to the caller
    cancelSent,    \* [Ids -> BOOLEAN]: a cancel signal was sent for the request
    progress,      \* [Ids -> 0..MaxProgress]: last accepted progress value
    everDone,      \* ghost [Ids -> BOOLEAN]: the request has finished before
    peerAnswered,  \* ghost [Ids -> BOOLEAN]: a response arrived while in flight
    progressSeen   \* ghost: <<id, status>> at each accepted progress notification

vars == <<req, outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen>>

Init ==
    /\ req = [id \in Ids |-> "unused"]
    /\ outcome = [id \in Ids |-> "none"]
    /\ delivered = [id \in Ids |-> 0]
    /\ cancelSent = [id \in Ids |-> FALSE]
    /\ progress = [id \in Ids |-> 0]
    /\ everDone = [id \in Ids |-> FALSE]
    /\ peerAnswered = [id \in Ids |-> FALSE]
    /\ progressSeen = {}

\* Ends a request with outcome o and hands o to the caller.
Finish(id, o) ==
    /\ req' = [req EXCEPT ![id] = "done"]
    /\ outcome' = [outcome EXCEPT ![id] = o]
    /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
    /\ everDone' = [everDone EXCEPT ![id] = TRUE]

\* The client sends a request with a fresh id (WIRE-01).
Send(id) ==
    /\ req[id] = "unused"
    /\ req' = [req EXCEPT ![id] = "inflight"]
    /\ UNCHANGED <<outcome, delivered, cancelSent, progress, everDone, peerAnswered, progressSeen>>

Accept(id, kind) ==
    /\ Finish(id, kind)
    /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
    /\ UNCHANGED <<cancelSent, progress, progressSeen>>

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
    /\ UNCHANGED <<progress, peerAnswered, progressSeen>>

\* The hard timeout fires (REQ-03). The outcome is a local error, never a
\* peer error (WIRE-10). Initialize times out without a cancel signal. A
\* listen has no timeout.
TimedOut(id) ==
    /\ req[id] = "inflight"
    /\ id \notin ListenIds
    /\ Finish(id, "timed_out")
    /\ cancelSent' = [cancelSent EXCEPT ![id] = ~(id \in InitIds)]
    /\ UNCHANGED <<progress, peerAnswered, progressSeen>>

\* The transport fails before the response: a stream breaks or the server
\* process exits. Re-sending is a new request with a new id (U06).
TransportLost(id) ==
    /\ req[id] = "inflight"
    /\ Finish(id, "lost")
    /\ UNCHANGED <<cancelSent, progress, peerAnswered, progressSeen>>

\* A progress notification for id's token. It is accepted only while the
\* request is in flight and only when the value increases (REQ-04, WIRE-06).
ProgressReceived(id, p) ==
    IF req[id] = "inflight" /\ p > progress[id]
    THEN /\ progress' = [progress EXCEPT ![id] = p]
         /\ progressSeen' = progressSeen \cup {<<id, req[id]>>}
         /\ UNCHANGED <<req, outcome, delivered, cancelSent, everDone, peerAnswered>>
    ELSE UNCHANGED vars

\* The server sends notifications/cancelled naming a client request. That
\* ends a listen in flight: the server tore the subscription down (SUBS-03).
\* For any other request it is never valid, so it is ignored (REQ-05).
ServerCancelReceived(id) ==
    IF id \in ListenIds /\ req[id] = "inflight"
    THEN /\ Finish(id, "ended")
         /\ peerAnswered' = [peerAnswered EXCEPT ![id] = TRUE]
         /\ UNCHANGED <<cancelSent, progress, progressSeen>>
    ELSE UNCHANGED vars

Next ==
    \E id \in Ids:
        \/ Send(id)
        \/ \E kind \in PeerKind: ResponseReceived(id, kind)
        \/ CancelRequested(id)
        \/ TimedOut(id)
        \/ TransportLost(id)
        \/ \E p \in 1..MaxProgress: ProgressReceived(id, p)
        \/ ServerCancelReceived(id)

Spec == Init /\ [][Next]_vars /\ \A id \in Ids: WF_vars(TimedOut(id))

TypeOK ==
    /\ req \in [Ids -> Status]
    /\ outcome \in [Ids -> Outcome]
    /\ delivered \in [Ids -> 0..2]
    /\ cancelSent \in [Ids -> BOOLEAN]
    /\ progress \in [Ids -> 0..MaxProgress]
    /\ everDone \in [Ids -> BOOLEAN]
    /\ peerAnswered \in [Ids -> BOOLEAN]
    /\ progressSeen \subseteq (Ids \X Status)

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
CancelValid == \A id \in Ids: cancelSent[id] => outcome[id] \in {"cancelled", "timed_out"}

\* REQ-06, LHTTP-08: initialize is never cancelled.
NeverCancelInitialize == \A id \in InitIds: ~cancelSent[id]

\* REQ-04, WIRE-06: progress is accepted only for requests in flight.
ProgressScoped == \A x \in progressSeen: x[2] = "inflight"

\* REQ-03: every request in flight but a listen eventually ends.
EveryRequestEnds == \A id \in Ids \ ListenIds: req[id] = "inflight" ~> req[id] = "done"
====
