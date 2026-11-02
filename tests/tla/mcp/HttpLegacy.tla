---- MODULE HttpLegacy ----
\* U07 Streamable HTTP with 2025 sessions, client side, one endpoint.
\* Rules: LHTTP-01..LHTTP-08 (rules.md).
\*
\*   - Session: initialize goes out without a session id, and its answer may
\*     assign one (fresh numbers from 1). Later POSTs, GETs, and the DELETE
\*     carry the current one (LHTTP-01; the trace wrapper checks the id each
\*     send carried).
\*   - Expiry: the server may end the session at any time and then answers 404
\*     to anything carrying its id. The client re-initializes once per ended
\*     session and re-sends, once, only the requests that got that 404, which
\*     the server never ran (LHTTP-02; rmcp's recovery).
\*   - Streams: a request's stream may carry event ids and may break. One that
\*     broke after an event id is resumed with GET and Last-Event-ID once its
\*     retry wait is over, at most MaxResumes times, and only in the session it
\*     started in. One without an event id is lost and never re-POSTed
\*     (LHTTP-05). An answer over the message limit is lost at once and
\*     never resumed: it would come the same again (LHTTP-11). A
\*     disconnect is not a cancel; cancelling posts
\*     notifications/cancelled (LHTTP-08). A request holds a stream only
\*     while it waits on one: once it ends, answered too, the client closes
\*     what the server left open (LHTTP-10).
\*   - The listening GET stream: one at most, opened only when ready, never
\*     again after a 405 (LHTTP-06).
\*   - Close: a DELETE if the session has an id the client hasn't seen end
\*     (LHTTP-03); nothing is sent after it.
\*
\* Timeouts belong to U02: here they are a cancel, which may or may not
\* happen. Fairness is on the client's own steps and on the server acting on
\* each open stream, so every request ends without relying on a timeout.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Requests,      \* request ids
    MaxSessions,   \* session ids the server may hand out
    MaxEvents,     \* event ids the server may send in total
    MaxResumes     \* resumes per request stream

ASSUME MaxSessions \in Nat \ {0} /\ MaxEvents \in Nat /\ MaxResumes \in Nat

Phases == {"start", "initializing", "ready", "failed", "closed"}
States == {"idle", "posted", "broken", "resuming", "queued", "done"}
Outcomes == {"none", "result", "lost", "failed", "cancelled"}
Open == {"posted", "resuming"}
Pending == {"posted", "broken", "resuming", "queued"}

VARIABLES
    phase,
    sid,           \* the current session id, 0 when the server assigned none
    nextSid,
    seenEnd,       \* session ids the client saw end (a 404 carrying them)
    req,           \* request id -> record
    nextEvent,
    listen,        \* "off", "open", "waiting", "none" (the server has none)
    deleted,
    \* Server side and ghosts.
    serverEnded,   \* session ids the server ended
    inits,         \* initialize requests sent
    sentClosed,    \* something was sent after close
    refused405,    \* the server answered the listening GET with 405
    listenAfter405,
    crossResume    \* a stream was resumed in another session

session == <<phase, sid, nextSid, seenEnd>>
ghosts == <<serverEnded, inits, sentClosed, refused405, listenAfter405, crossResume>>
vars == <<session, req, nextEvent, listen, deleted, ghosts>>

Record == [st: States, sid: 0..MaxSessions, posts: Nat, after404: BOOLEAN,
           ev: BOOLEAN, resumes: 0..MaxResumes, outcome: Outcomes, stream: BOOLEAN]

Fresh == [st |-> "idle", sid |-> 0, posts |-> 0, after404 |-> FALSE,
          ev |-> FALSE, resumes |-> 0, outcome |-> "none", stream |-> FALSE]

Init ==
    /\ phase = "start"
    /\ sid = 0
    /\ nextSid = 1
    /\ seenEnd = {}
    /\ req = [r \in Requests |-> Fresh]
    /\ nextEvent = 1
    /\ listen = "off"
    /\ deleted = FALSE
    /\ serverEnded = {}
    /\ inits = 0
    /\ sentClosed = FALSE
    /\ refused405 = FALSE
    /\ listenAfter405 = FALSE
    /\ crossResume = FALSE

\* Nothing reads a finished request's stream, so the client closes it.
End(r, o) == [req[r] EXCEPT !.st = "done", !.outcome = o, !.stream = FALSE]

\* Every request still pending ends with `o`.
EndAll(o) == [r \in Requests |-> IF req[r].st \in Pending THEN End(r, o) ELSE req[r]]

\* A send by the client: none may happen after close.
Sent == sentClosed' = (sentClosed \/ phase = "closed")

\* A 404 carrying session s: re-initialize if s is the current session and no
\* re-initialize is under way. Every initialize answer changes `sid`, so this
\* happens once per session.
SawEnd(s) ==
    /\ seenEnd' = seenEnd \cup {s}
    /\ IF s = sid /\ phase = "ready"
       THEN /\ phase' = "initializing"
            /\ inits' = inits + 1
       ELSE UNCHANGED <<phase, inits>>

---------------------------------------------------------------------------
\* Client actions.

Start ==
    /\ phase = "start"
    /\ phase' = "initializing"
    /\ inits' = inits + 1
    /\ Sent
    /\ UNCHANGED <<sid, nextSid, seenEnd, req, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, refused405, listenAfter405, crossResume>>

\* The host sends r, or a request that got a 404 goes out again in the new
\* session.
Post(r) ==
    /\ phase = "ready"
    /\ req[r].st \in {"idle", "queued"}
    /\ req' = [req EXCEPT ![r] = [@ EXCEPT !.st = "posted", !.sid = sid, !.posts = @ + 1,
                                           !.ev = FALSE, !.resumes = 0, !.stream = TRUE]]
    /\ Sent
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>

\* A request the host sends before the session is ready waits for it.
Hold(r) ==
    /\ phase \in {"start", "initializing"}
    /\ req[r].st = "idle"
    /\ req' = [req EXCEPT ![r].st = "queued"]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>

\* The retry wait is over: resume in the same session, or the stream is lost.
ResumeDue(r) ==
    /\ req[r].st = "broken"
    /\ IF phase = "ready" /\ req[r].sid = sid
       THEN /\ req' = [req EXCEPT ![r] = [@ EXCEPT !.st = "resuming", !.resumes = @ + 1, !.stream = TRUE]]
            /\ Sent
       ELSE /\ req' = [req EXCEPT ![r] = End(r, "lost")]
            /\ UNCHANGED sentClosed
    /\ crossResume' = (crossResume \/ (req'[r].st = "resuming" /\ req[r].sid # sid))
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405>>

\* The host cancels, or the request timed out (U02): a notifications/cancelled
\* POST when the request is out in the current session.
Cancel(r) ==
    /\ req[r].st \in Pending
    /\ req' = [req EXCEPT ![r] = End(r, "cancelled")]
    /\ IF req[r].st # "queued" /\ phase = "ready" /\ req[r].sid = sid THEN Sent ELSE UNCHANGED sentClosed
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>

ListenOpen ==
    /\ phase = "ready"
    /\ listen = "off"
    /\ listen' = "open"
    /\ listenAfter405' = (listenAfter405 \/ refused405)
    /\ Sent
    /\ UNCHANGED <<session, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, crossResume>>

\* The wait after a broken listening stream is over.
ListenDue ==
    /\ listen = "waiting"
    /\ listen' = "off"
    /\ UNCHANGED <<session, req, nextEvent, deleted, ghosts>>

Close ==
    /\ phase \in {"start", "initializing", "ready"}
    /\ phase' = "closed"
    \* A 404 for the current session always starts a new one, so a ready
    \* session's id is live.
    /\ deleted' = (phase = "ready" /\ sid # 0)
    /\ IF deleted' THEN Sent ELSE UNCHANGED sentClosed
    /\ req' = EndAll("cancelled")
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<sid, nextSid, seenEnd, nextEvent>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>

---------------------------------------------------------------------------
\* Server actions.

\* initialize is answered, with a fresh session id or none. Requests from the
\* old session go on; a stream of it can't be resumed any more.
InitAnswered(withId) ==
    /\ phase = "initializing"
    /\ withId => nextSid <= MaxSessions
    /\ phase' = "ready"
    /\ sid' = IF withId THEN nextSid ELSE 0
    /\ nextSid' = IF withId THEN nextSid + 1 ELSE nextSid
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<seenEnd, req, nextEvent, deleted, ghosts>>

\* initialize fails, a 404 included (it carried no session id): no loop.
InitFailed ==
    /\ phase = "initializing"
    /\ phase' = "failed"
    /\ req' = EndAll("failed")
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<sid, nextSid, seenEnd, nextEvent, deleted, ghosts>>

EndSession ==
    /\ sid # 0
    /\ sid \notin serverEnded
    /\ serverEnded' = serverEnded \cup {sid}
    /\ UNCHANGED <<session, req, nextEvent, listen, deleted>>
    /\ UNCHANGED <<inits, sentClosed, refused405, listenAfter405, crossResume>>

Event(r) ==
    /\ req[r].st \in Open
    /\ nextEvent <= MaxEvents
    /\ req' = [req EXCEPT ![r].ev = TRUE]
    /\ nextEvent' = nextEvent + 1
    /\ UNCHANGED <<session, listen, deleted, ghosts>>

Answer(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, "result")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>

\* The stream breaks: resumable after an event id, while resumes are left.
Break(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = IF req[r].ev /\ req[r].resumes < MaxResumes
                                 THEN [@ EXCEPT !.st = "broken", !.stream = FALSE]
                                 ELSE End(r, "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>

\* The answer is over the message limit, on a posted or resumed stream: lost
\* at once, since resuming would only bring it again (LHTTP-11).
TooLarge(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>

\* A status without a JSON-RPC answer, other than a session 404: the POST
\* failed; a resumed stream is lost (the request may have run).
Refused(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, IF req[r].st = "posted" THEN "failed" ELSE "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>

\* A 404 to something carrying an ended session's id. A POST goes out again,
\* once, in the next session; a resumed stream is lost.
Expired(r) ==
    /\ req[r].st \in Open
    /\ req[r].sid \in serverEnded
    /\ req' = [req EXCEPT ![r] = IF req[r].st = "resuming" \/ req[r].after404
                                 THEN End(r, IF req[r].st = "resuming" THEN "lost" ELSE "failed")
                                 ELSE [@ EXCEPT !.st = "queued", !.after404 = TRUE, !.stream = FALSE]]
    /\ SawEnd(req[r].sid)
    /\ UNCHANGED <<sid, nextSid, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, sentClosed, refused405, listenAfter405, crossResume>>

ListenRefused ==
    /\ listen = "open"
    /\ listen' = "none"
    /\ refused405' = TRUE
    /\ UNCHANGED <<session, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, inits, sentClosed, listenAfter405, crossResume>>

ListenBroke ==
    /\ listen = "open"
    /\ listen' = "waiting"
    /\ UNCHANGED <<session, req, nextEvent, deleted, ghosts>>

ListenExpired ==
    /\ listen = "open"
    /\ sid \in serverEnded
    /\ listen' = "off"
    /\ SawEnd(sid)
    /\ UNCHANGED <<sid, nextSid, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, sentClosed, refused405, listenAfter405, crossResume>>

---------------------------------------------------------------------------

Client ==
    \/ Start
    \/ \E r \in Requests : Post(r) \/ Hold(r) \/ ResumeDue(r) \/ Cancel(r)
    \/ ListenOpen \/ ListenDue \/ Close

Server ==
    \/ InitAnswered(TRUE) \/ InitAnswered(FALSE) \/ InitFailed \/ EndSession
    \/ \E r \in Requests : Event(r) \/ Answer(r) \/ Break(r) \/ TooLarge(r) \/ Refused(r) \/ Expired(r)
    \/ ListenRefused \/ ListenBroke \/ ListenExpired

Next == Client \/ Server

\* The client keeps going: initialize goes out, queued requests are sent,
\* waits end. The server eventually answers initialize, and acts on every open
\* stream. Cancel and Close are never forced.
Fairness ==
    /\ WF_vars(Start)
    /\ \A r \in Requests : WF_vars(Post(r)) /\ WF_vars(ResumeDue(r))
    /\ WF_vars(InitAnswered(TRUE) \/ InitAnswered(FALSE) \/ InitFailed)
    /\ \A r \in Requests : WF_vars(Answer(r) \/ Break(r) \/ TooLarge(r) \/ Refused(r) \/ Expired(r))

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------
\* Properties.

TypeOK ==
    /\ phase \in Phases
    /\ sid \in 0..MaxSessions
    /\ nextSid \in 1..(MaxSessions + 1)
    /\ seenEnd \subseteq 1..MaxSessions
    /\ req \in [Requests -> Record]
    /\ nextEvent \in 1..(MaxEvents + 1)
    /\ listen \in {"off", "open", "waiting", "none"}
    /\ deleted \in BOOLEAN
    /\ serverEnded \subseteq 1..MaxSessions

\* LHTTP-02: re-initialize only for a session the server ended, once each.
OneInitPerEnd == inits <= 1 + Cardinality(seenEnd)
SeenOnlyEnded == seenEnd \subseteq serverEnded

\* LHTTP-05: a POST goes out again only after a 404, and only once.
NoReplayOfLostPost == \A r \in Requests :
    /\ req[r].posts <= 2
    /\ req[r].posts = 2 => req[r].after404

\* LHTTP-05: only a stream that carried an event id is resumed, and only in
\* the session it started in.
ResumeAfterEventId == \A r \in Requests :
    req[r].st \in {"broken", "resuming"} => req[r].ev /\ req[r].resumes <= MaxResumes
ResumeSameSession == ~crossResume

\* LHTTP-11: an answer over the message limit ends its request, lost; the
\* stream is never resumed for it. An action property, so it adds no state.
TooLargeEnds == [][\A r \in Requests : TooLarge(r) => req'[r].st = "done" /\ req'[r].outcome = "lost"]_vars

\* LHTTP-03: nothing goes out after close, and the DELETE only names a live session.
NothingAfterClose == ~sentClosed
DeleteOnlyLive == deleted => phase = "closed" /\ sid # 0 /\ sid \notin seenEnd

\* LHTTP-06: no listening stream once the server said it has none.
ListenRespects405 == ~listenAfter405

\* LHTTP-10: a request holds a stream only while it waits on one.
StreamOnlyWhileOpen == \A r \in Requests : req[r].stream => req[r].st \in Open

\* Every request the host sent ends, and a session the client saw end is
\* replaced (or the client stops).
EveryRequestEnds == \A r \in Requests : (req[r].st # "idle") ~> (req[r].st = "done")
ExpiryReinits == \A s \in 1..MaxSessions :
    (s \in seenEnd) ~> (sid # s \/ phase \in {"failed", "closed"})
====
