---- MODULE HttpLegacyTrace ----
\* Trace wrapper for HttpLegacy.tla (U07). tests/bun/bridge.ts generates TraceObs
\* from machine "http_legacy".
\*
\* Mapping from the Zig core (src/mcp/core/http_legacy.zig):
\*   - Each record is one model action, named in snake_case; one core step may
\*     write several (the client actions an initialize answer enables at once).
\*   - Requests are the request ids in the trace; id 0 is none.
\*   - The server ending a session isn't visible to the client. The core writes
\*     `end_session` at the first 404 that shows it (EndSession).
\*   - Bounds come from the trace: MaxSessions is the highest session number,
\*     MaxEvents the number of event records. MaxResumes is the scenario's.
\*   - A record marked `ignored` is accepted only where the model's action is
\*     disabled, and nothing may change.
\*   - Only the stepped request is compared; its fields are absent when the
\*     core has no request under that id.
EXTENDS HttpLegacy, TraceObs, Naturals, Sequences

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
Has(r, f) == f \in DOMAIN r.data
ObsRequests == {r.data.id : r \in {x \in Recs : x.data.id # 0}}
ObsSids == {r.data.sid : r \in Recs}
ObsMaxSid == CHOOSE m \in ObsSids : \A q \in ObsSids : q <= m
ObsMaxSessions == IF ObsMaxSid = 0 THEN 1 ELSE ObsMaxSid
ObsMaxEvents == Cardinality({k \in 1..Len(ObsTrace) : ObsTrace[k].event = "event"})

Step(r, id) ==
    CASE r.event = "start" -> Start
      [] r.event = "post" -> Post(id)
      [] r.event = "hold" -> Hold(id)
      [] r.event = "init_answered_with_id" -> InitAnswered(TRUE)
      [] r.event = "init_answered_without_id" -> InitAnswered(FALSE)
      [] r.event = "init_failed" -> InitFailed
      [] r.event = "end_session" -> EndSession
      [] r.event = "event" -> Event(id)
      [] r.event = "answer" -> Answer(id)
      [] r.event = "break" -> Break(id)
      [] r.event = "too_large" -> TooLarge(id)
      [] r.event = "refused" -> Refused(id)
      [] r.event = "expired" -> Expired(id)
      [] r.event = "resume_due" -> ResumeDue(id)
      [] r.event = "cancel" -> Cancel(id)
      [] r.event = "listen_open" -> ListenOpen
      [] r.event = "listen_refused" -> ListenRefused
      [] r.event = "listen_broke" -> ListenBroke
      [] r.event = "listen_due" -> ListenDue
      [] r.event = "listen_expired" -> ListenExpired
      [] r.event = "close" -> Close
      [] OTHER -> FALSE

Matches(r, id) ==
    /\ phase' = r.to
    /\ sid' = r.data.sid
    /\ listen' = r.data.listen
    /\ deleted' = r.data.deleted
    /\ Has(r, "st") =>
        /\ req'[id].st = r.data.st
        /\ req'[id].sid = r.data.req_sid
        /\ req'[id].posts = r.data.posts
        /\ req'[id].after404 = r.data.after404
        /\ req'[id].ev = r.data.ev
        /\ req'[id].resumes = r.data.resumes

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
           id == r.data.id
       IN /\ phase = r.from
          /\ IF r.data.ignored THEN ~ENABLED Step(r, id) /\ UNCHANGED vars ELSE Step(r, id)
          /\ Matches(r, id)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====
