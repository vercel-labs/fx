---- MODULE UrlRetryTrace ----
\* Trace wrapper for UrlRetry.tla. trace.ts generates TraceObs from a real
\* `fx ask` in a terminal against tests/e2e/fixtures/mcp-legacy-stdio.mjs, a
\* 2025-11-25 server that answers the first tools/call with -32042
\* (tests/tla/drivers/mcp_host/url-retry.test.ts).
\*   call {n}          the fixture has had n tools/call requests
\*   required {}       fx shows the first URL, so the -32042 answer came
\*   consent_shown {}  fx's terminal asks to open a URL
\*   accept {}         the harness chose Open URL for every URL
\*   waiting_shown {}  fx's terminal shows "I completed it / Retry"
\*   complete {url}    the fixture completed URL `url`
\*   ignored {}        the fixture sent completions for an unknown id and
\*                     for a URL already completed
\*   retry {}          the harness chose "I completed it / Retry"
\*   cancel {}         the harness chose Cancel
\*   result {}         the fixture answered the call with its result
\*   end {how}         the call is over: "result", "declined", "cancelled"
\* fx calling again on its own, at the signal, shows only as the next `call`.
EXTENDS UrlRetry, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF CountsOwnCompletions THEN {} ELSE {"CountsOwnCompletions"}) \cup
    (IF SeenWhenDone THEN {} ELSE {"SeenWhenDone"}) \cup
    (IF SignalTruth THEN {} ELSE {"SignalTruth"}) \cup
    (IF RetryOnlyAfterProof THEN {} ELSE {"RetryOnlyAfterProof"}) \cup
    (IF EndsByUserOrServer THEN {} ELSE {"EndsByUserOrServer"})

Step(rec) ==
    CASE rec.event = "call" -> calls = rec.data.n /\ UNCHANGED vars
      [] rec.event = "required" -> ServerRequires
      [] rec.event = "consent_shown" -> phase = "consent" /\ UNCHANGED vars
      [] rec.event = "accept" -> UserAccepts
      [] rec.event = "waiting_shown" -> phase = "waiting" /\ UNCHANGED vars
      [] rec.event = "complete" ->
            \E s \in SlotIds : ownCall[s] = calls /\ ownUrl[s] = rec.data.url /\ ServerCompletes(s)
      [] rec.event = "ignored" -> UNCHANGED vars
      [] rec.event = "retry" -> UserRetries
      [] rec.event = "cancel" -> UserCancels
      [] rec.event = "result" -> ServerAnswers
      [] rec.event = "end" -> phase = "done" /\ ended = rec.data.how /\ UNCHANGED vars
      [] OTHER -> FALSE

\* What fx does with no record: call again when the signal closes the question.
Hidden == AutoRetry

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
