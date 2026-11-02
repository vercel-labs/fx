---- MODULE Mrtr ----
\* U08 multi round-trip requests (2026), client side: one chain of rounds for
\* one tools/call. Rules: MRTR-01..MRTR-07 (rules.md).
\*
\*   - Each round is a new request with a new id (MRTR-03; U02 proves ids are
\*     never reused). The server answers it with a final result, an error, no
\*     answer (lost), a malformed input_required, or an input_required that
\*     carries input requests (Keys of them, abstractly a count), a
\*     requestState, or both.
\*   - Input requests for a capability the client didn't declare end the
\*     chain; the host is never asked. Otherwise the host provides every
\*     answer, or cancels.
\*   - A round with only a requestState is retried after a backoff.
\*   - The retry echoes the requestState of the round before it, or none if it
\*     had none, and answers exactly the keys it was asked (MRTR-02..04).
\*   - At most MaxRequests requests per chain.
\*
\* A requestState is identified by the round that brought it; strings, keys,
\* and the backoff times are data, checked by the Zig tests.
EXTENDS Naturals

CONSTANTS
    MaxRequests,   \* requests per chain (10)
    MaxKeys        \* input requests per round in the model

ASSUME MaxRequests \in Nat \ {0} /\ MaxKeys \in Nat \ {0}

Outcomes == {"none", "result", "failure", "lost", "http_failure", "cancelled",
             "rounds_exceeded", "unsupported_input", "malformed"}

VARIABLES
    phase,       \* "idle", "sent", "asking", "backoff", "done"
    round,       \* requests sent
    lastState,   \* the round whose answer brought the current requestState, 0 for none
    requested,   \* input requests in the last input_required
    supported,   \* every one of them is for a declared capability
    sentState,   \* the requestState the latest request carried, 0 for none
    responded,   \* input responses the latest request carried
    outcome,
    \* Ghosts.
    brought,     \* the requestState the latest answer carried, 0 for none
    sentDone     \* a request went out after the chain ended

vars == <<phase, round, lastState, requested, supported, sentState, responded, outcome, brought, sentDone>>

Init ==
    /\ phase = "idle"
    /\ round = 0
    /\ lastState = 0
    /\ requested = 0
    /\ supported = TRUE
    /\ sentState = 0
    /\ responded = 0
    /\ outcome = "none"
    /\ brought = 0
    /\ sentDone = FALSE

\* A request goes out: the retry of the round before it.
Send ==
    /\ round' = round + 1
    /\ sentState' = lastState
    /\ sentDone' = (sentDone \/ phase = "done")

Start ==
    /\ phase = "idle"
    /\ phase' = "sent"
    /\ responded' = 0
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>

\* The server's answer to the latest request.
Ended(o) ==
    /\ phase = "sent"
    /\ phase' = "done"
    /\ outcome' = o
    /\ UNCHANGED <<round, lastState, requested, supported, sentState, responded, brought, sentDone>>

Malformed == Ended("malformed")

InputRequired(n, st, sup) ==
    /\ phase = "sent"
    /\ n > 0 \/ st
    /\ requested' = n
    /\ supported' = sup
    /\ lastState' = IF st THEN round ELSE 0
    /\ brought' = IF st THEN round ELSE 0
    /\ IF round = MaxRequests
       THEN phase' = "done" /\ outcome' = "rounds_exceeded"
       ELSE IF n > 0 /\ ~sup
       THEN phase' = "done" /\ outcome' = "unsupported_input"
       ELSE IF n > 0
       THEN phase' = "asking" /\ UNCHANGED outcome
       ELSE phase' = "backoff" /\ UNCHANGED outcome
    /\ UNCHANGED <<round, sentState, responded, sentDone>>

\* The host answered every input request (MRTR-02).
Provide ==
    /\ phase = "asking"
    /\ phase' = "sent"
    /\ responded' = requested
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>

\* A round with only a requestState: retried after the backoff.
BackoffDone ==
    /\ phase = "backoff"
    /\ phase' = "sent"
    /\ responded' = 0
    /\ Send
    /\ UNCHANGED <<lastState, requested, supported, outcome, brought>>

\* The host cancels, or the request timed out (U02).
Cancel ==
    /\ phase \in {"sent", "asking", "backoff"}
    /\ phase' = "done"
    /\ outcome' = "cancelled"
    /\ UNCHANGED <<round, lastState, requested, supported, sentState, responded, brought, sentDone>>

Server ==
    \/ \E o \in {"result", "failure", "lost", "http_failure"} : Ended(o)
    \/ Malformed
    \/ \E n \in 0..MaxKeys, st \in BOOLEAN, sup \in BOOLEAN : InputRequired(n, st, sup)

Next == Start \/ Provide \/ BackoffDone \/ Cancel \/ Server

\* The client keeps going, a host that is asked eventually answers or
\* cancels, and the server answers every request somehow. Cancel is fair only
\* while the host is asked: elsewhere it would end a stuck chain and hide it.
HostAnswers == Provide \/ (phase = "asking" /\ Cancel)

Fairness ==
    /\ WF_vars(Start)
    /\ WF_vars(BackoffDone)
    /\ WF_vars(HostAnswers)
    /\ WF_vars(Server)

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------
\* Properties.

TypeOK ==
    /\ phase \in {"idle", "sent", "asking", "backoff", "done"}
    /\ round \in 0..(MaxRequests + 1)
    /\ lastState \in 0..MaxRequests
    /\ requested \in 0..MaxKeys
    /\ supported \in BOOLEAN
    /\ sentState \in 0..MaxRequests
    /\ responded \in 0..MaxKeys
    /\ outcome \in Outcomes

\* MRTR-04: the request out carries the requestState the answer before it
\* brought, or none.
StateEchoExact == phase = "sent" => sentState = brought

\* A round is backed off only when it carried a requestState: an
\* input_required with neither field is malformed.
BackoffNeedsState == phase = "backoff" => brought # 0

\* MRTR-02, MRTR-03: it answers exactly the input requests it was asked.
ResponsesExact == phase = "sent" => responded = requested

\* The host is asked only for declared capabilities.
NoAskUnsupported == phase = "asking" => supported

\* A chain sends at most MaxRequests requests.
RoundCap == round <= MaxRequests

NothingAfterEnd == ~sentDone

EveryChainEnds == (phase # "idle") ~> (phase = "done")
====
