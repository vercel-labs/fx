---- MODULE HttpModern ----
\* U06 Streamable HTTP (2026), client side: one logical request and its
\* attempts. Rules: HTTP-01, HTTP-08, HTTP-09, HTTP-10, HTTP-13, CAT-09.
\*
\*
\* Each attempt is its own POST and its own U02 request, with a new id. An
\* attempt ends with a JSON-RPC answer (in a JSON body or an SSE stream, the
\* same here), an HTTP failure with no JSON-RPC body, or a stream that
\* breaks first. A broken stream is re-issued with a new id, but a tools/call
\* is never re-sent by the transport: it ends lost, flagged as maybe run.
\* An answer over the message limit ends the request lost at once, never
\* re-issued, as another attempt would bring the same answer (HTTP-14).
\* A -32020 to a tools/call means re-listing the tools and retrying once.
\* Cancelling closes the stream; HTTP has no notifications/cancelled (HTTP-08).
\* An answer closes its attempt's stream too: the final response ends it, and
\* the client closes one the server left open (HTTP-13).
EXTENDS Naturals

CONSTANTS
    MaxAttempts    \* POSTs per logical request after broken streams (2)

ASSUME MaxAttempts \in Nat \ {0}

Terminal == {"done", "lost", "failed", "cancelled"}

VARIABLES
    kind,          \* "call" (tools/call) or "idempotent" (listing, discovery, reads)
    phase,         \* "idle", "posted", "relisting", or a terminal phase
    attempts,      \* POSTs sent after broken streams, counting the first
    headerRetries, \* retries after -32020
    currentId,     \* the id of the attempt in flight
    nextId,        \* the next unused id
    outcome,       \* what the caller got: "none", "result", "error", "lost", "failed", "cancelled"
    maybeRan,      \* a lost tools/call may have run on the server
    closed,        \* the client closed the attempt's stream
    \* Ghost variables for the safety properties.
    usedIds,       \* every id an attempt has used
    reused,        \* an attempt reused an id
    delivered,     \* outcomes delivered to the caller
    cancelNote     \* notifications/cancelled was sent

vars == <<kind, phase, attempts, headerRetries, currentId, nextId, outcome, maybeRan,
          closed, usedIds, reused, delivered, cancelNote>>

Init ==
    /\ kind \in {"call", "idempotent"}
    /\ phase = "idle"
    /\ attempts = 0
    /\ headerRetries = 0
    /\ currentId = 0
    /\ nextId = 1
    /\ outcome = "none"
    /\ maybeRan = FALSE
    /\ closed = FALSE
    /\ usedIds = {}
    /\ reused = FALSE
    /\ delivered = 0
    /\ cancelNote = FALSE

\* POST an attempt with a fresh id.
Post ==
    /\ phase' = "posted"
    /\ currentId' = nextId
    /\ nextId' = nextId + 1
    /\ reused' = (reused \/ currentId' \in usedIds)
    /\ usedIds' = usedIds \cup {currentId'}
    /\ closed' = FALSE

Deliver(o) ==
    /\ outcome' = o
    /\ delivered' = delivered + 1

\* The host sends the request.
Send ==
    /\ phase = "idle"
    /\ attempts' = 1
    /\ Post
    /\ UNCHANGED <<kind, headerRetries, outcome, maybeRan, delivered, cancelNote>>

\* The attempt's answer: a result, an error, or -32020 (HeaderMismatch).
Answer(a) ==
    /\ phase = "posted"
    /\ IF a = "mismatch" /\ kind = "call" /\ headerRetries = 0
          THEN /\ phase' = "relisting"
               /\ headerRetries' = 1
               /\ UNCHANGED <<outcome, delivered>>
          ELSE /\ phase' = "done"
               /\ Deliver(IF a = "result" THEN "result" ELSE "error")
               /\ UNCHANGED headerRetries
    /\ closed' = TRUE    \* nothing more comes for the answered attempt
    /\ UNCHANGED <<kind, attempts, currentId, nextId, maybeRan, usedIds, reused, cancelNote>>

\* An HTTP status with no JSON-RPC body, for example 401, 403, or 502.
\* An attempt the auth gate gave up on ends so too, as the server's 401: the
\* server never read it, so a call never counts as maybe run.
HttpFailure ==
    /\ phase = "posted"
    /\ phase' = "failed"
    /\ Deliver("failed")
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, maybeRan, closed, usedIds, reused, cancelNote>>

\* The connection or stream broke before the answer (HTTP-09).
StreamBroken ==
    /\ phase = "posted"
    /\ IF kind = "idempotent" /\ attempts < MaxAttempts
          THEN /\ attempts' = attempts + 1
               /\ Post
               /\ UNCHANGED <<outcome, maybeRan, delivered>>
          ELSE /\ phase' = "lost"
               /\ maybeRan' = (kind = "call")
               /\ Deliver("lost")
               /\ UNCHANGED <<attempts, currentId, nextId, closed, usedIds, reused>>
    /\ UNCHANGED <<kind, headerRetries, cancelNote>>

\* The answer was over the message limit: lost at once, never re-issued, as
\* another attempt would bring the same answer (HTTP-14). A call may have run.
TooLarge ==
    /\ phase = "posted"
    /\ phase' = "lost"
    /\ maybeRan' = (kind = "call")
    /\ Deliver("lost")
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, closed, usedIds, reused, cancelNote>>

\* The re-list after -32020 ended: retry the call once, or give up.
Relisted(ok) ==
    /\ phase = "relisting"
    /\ IF ok
          THEN /\ Post
               /\ UNCHANGED <<outcome, delivered>>
          ELSE /\ phase' = "done"
               /\ Deliver("error")
               /\ UNCHANGED <<currentId, nextId, usedIds, reused, closed>>
    /\ UNCHANGED <<kind, attempts, headerRetries, maybeRan, cancelNote>>

\* The host cancels (or the U02 timeout fires): close the stream (HTTP-08).
Cancel ==
    /\ phase \in {"posted", "relisting"}
    /\ phase' = "cancelled"
    /\ closed' = TRUE
    /\ outcome' = "cancelled"
    /\ delivered' = delivered + 1
    /\ UNCHANGED <<kind, attempts, headerRetries, currentId, nextId, maybeRan, usedIds, reused,
                   cancelNote>>

Environment ==
    \/ \E a \in {"result", "error", "mismatch"} : Answer(a)
    \/ HttpFailure
    \/ StreamBroken
    \/ TooLarge
    \/ \E ok \in BOOLEAN : Relisted(ok)

Next == Send \/ Environment \/ Cancel

\* Every attempt ends (its U02 timers), and so does every re-list (U05).
Spec == Init /\ [][Next]_vars /\ WF_vars(Environment)

TypeOK ==
    /\ kind \in {"call", "idempotent"}
    /\ phase \in {"idle", "posted", "relisting"} \cup Terminal
    /\ attempts \in 0..MaxAttempts
    /\ headerRetries \in 0..1
    /\ maybeRan \in BOOLEAN
    /\ closed \in BOOLEAN

\* Each attempt has an id no earlier attempt used (HTTP-09).
ReissueNewId == ~reused

\* The caller gets one outcome at most, so nothing reaches it after a cancel.
AtMostOneOutcome == delivered <= 1

\* A tools/call is never re-sent after a broken stream.
NoCallResent == kind = "call" => attempts <= 1

\* Only a lost tools/call may have run.
MaybeRanOnlyForLostCalls == maybeRan => (kind = "call" /\ phase = "lost")

\* Cancelling closes the stream and sends no notification (HTTP-08).
CancelByClose == (phase = "cancelled" => closed) /\ ~cancelNote

\* An answered attempt holds no stream, even one the server left open (HTTP-13).
AnsweredStreamClosed == phase \in {"done", "relisting"} => closed

\* HTTP-14: an answer over the message limit ends the request, lost, and
\* nothing asks for it again. An action property, so it adds no state.
TooLargeEnds == [][TooLarge => phase' = "lost"]_vars

\* Every request ends.
EveryRequestEnds == phase \in {"posted", "relisting"} ~> phase \in Terminal
====
