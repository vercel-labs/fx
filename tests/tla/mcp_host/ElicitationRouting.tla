---- MODULE ElicitationRouting ----
\* Where fx routes an MCP server's questions and the user's answers
\* (vercel-labs/fx at 53a561bea), for one server and one call that can ask.
\*
\* Code:
\*   - src/core/mcp_host/runtime.zig onServer `.elicit` (2025): callAsking
\*     finds a call on the server that can ask and isn't holding a question
\*     (req.question == null), and offers it Pending{reply = .elicit = slot};
\*     with none, fx answers it cancel at once. `.elicit_withdrawn`: endUrl only.
\*   - onEvent `.input` (2026): the call's input requests, offered as
\*     Pending{reply = .input = {call handle, keys}}.
\*   - askWaiting, on the caller's thread: takes the offered question
\*     (req.question = null), asks the user, and posts the answer with the
\*     Pending it took. `.answer` on the owner: engine.answerElicitation
\*     (server, slot, answer) for 2025; engine.respond(call handle, values)
\*     for 2026.
\*   - finish(req): a question the caller hadn't taken goes with the call.
\*   - src/mcp/core/elicitation.zig Table.step `.asked`: the lowest free slot
\*     (a slot is reused once freed); `.server_cancelled` frees it.
\*   - src/mcp/engine.zig call: handles are never reused (next_handle).
\*
\* Questions are numbered 1..MaxQ as the server asks them. A 2025 question
\* holds a slot in 0..Slots-1; a 2026 one is keyed by its call and round,
\* which are never reused, so its key is its number. Guard = TRUE is the
\* repaired code: a 2025 answer carries the
\* question's number too, the owner drops it unless that question still
\* holds the slot, and a withdrawn question the call hasn't shown is dropped.
\* Guard = FALSE is the code before it, which smoke, stress and findings check.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Versions,   \* SUBSET {"2025", "2026"}: the server's protocol version
    MaxQ,       \* questions the server asks
    Slots,      \* 2025 slots (the core's max_pending)
    Guard       \* BOOLEAN

Qs == 1..MaxQ
SlotIds == 0..(Slots - 1)
None == 0

VARIABLES
    version,    \* the server's version, fixed
    nextQ,      \* the next question's number
    holder,     \* [SlotIds -> 0..MaxQ]: 2025 slot table (0 free)
    pending,    \* [Qs -> BOOLEAN]: the server still waits for its answer
    calling,    \* a call that can ask is running
    offered,    \* the call's req.question: 0 or a question
    offerKey,   \* the reply that Pending carries: a slot (2025) or the question (2026)
    asking,     \* the question the user sees: 0 or a question
    askKey,     \* the reply the caller took with it
    posted,     \* an answer posted to the owner: [q, key], q = 0 for none
    answeredBy, \* [Qs -> 0..MaxQ]: whose answer the server got for each question
    shown,      \* ghost: [Qs -> BOOLEAN] the user saw it
    dismissed    \* ghost: [Qs -> BOOLEAN] fx dismissed it at once

vars == <<version, nextQ, holder, pending, calling, offered, offerKey, asking, askKey, posted, answeredBy, shown, dismissed>>

Free == {s \in SlotIds : holder[s] = None}
Lowest(S) == CHOOSE s \in S : \A t \in S : s <= t

TypeOK ==
    /\ version \in Versions
    /\ nextQ \in 1..(MaxQ + 1)
    /\ holder \in [SlotIds -> 0..MaxQ]
    /\ pending \in [Qs -> BOOLEAN]
    /\ calling \in BOOLEAN
    /\ offered \in 0..MaxQ /\ asking \in 0..MaxQ
    /\ offerKey \in 0..MaxQ /\ askKey \in 0..MaxQ
    /\ posted \in [q : 0..MaxQ, key : 0..MaxQ]
    /\ answeredBy \in [Qs -> 0..MaxQ]
    /\ shown \in [Qs -> BOOLEAN]
    /\ dismissed \in [Qs -> BOOLEAN]

Init ==
    /\ version \in Versions
    /\ nextQ = 1
    /\ holder = [s \in SlotIds |-> None]
    /\ pending = [q \in Qs |-> FALSE]
    /\ calling = TRUE
    /\ offered = None /\ offerKey = 0
    /\ asking = None /\ askKey = 0
    /\ posted = [q |-> None, key |-> 0]
    /\ answeredBy = [q \in Qs |-> None]
    /\ shown = [q \in Qs |-> FALSE]
    /\ dismissed = [q \in Qs |-> FALSE]

\* The server asks question q. 2025: the core takes the lowest free slot
\* (none free: an error answers it, and it never reaches fx). 2026: a round.
\* fx offers it to the call, or answers it cancel at once when no call can take it.
Ask ==
    /\ nextQ <= MaxQ
    /\ version = "2025" => Free # {}
    /\ LET q == nextQ
           s == IF version = "2025" THEN Lowest(Free) ELSE 0
           take == calling /\ offered = None
       IN /\ nextQ' = nextQ + 1
          /\ holder' = IF version = "2025" /\ take THEN [holder EXCEPT ![s] = q] ELSE holder
          /\ pending' = [pending EXCEPT ![q] = take]
          /\ offered' = IF take THEN q ELSE offered
          /\ offerKey' = IF take THEN (IF version = "2025" THEN s ELSE q) ELSE offerKey
          \* fx's cancel goes out at once, as this question's answer.
          /\ answeredBy' = IF take THEN answeredBy ELSE [answeredBy EXCEPT ![q] = q]
          /\ dismissed' = [dismissed EXCEPT ![q] = ~take]
    /\ UNCHANGED <<version, calling, asking, askKey, posted, shown>>

\* askWaiting: the caller's thread takes the offered question and shows it.
Take ==
    /\ offered # None /\ asking = None
    /\ asking' = offered /\ askKey' = offerKey
    /\ offered' = None /\ offerKey' = 0
    /\ shown' = [shown EXCEPT ![offered] = TRUE]
    /\ UNCHANGED <<version, nextQ, holder, pending, calling, posted, answeredBy, dismissed>>

\* The user answers what they see; the caller posts it to the owner.
UserAnswers ==
    /\ asking # None /\ posted.q = None
    /\ posted' = [q |-> asking, key |-> askKey]
    /\ asking' = None /\ askKey' = 0
    /\ UNCHANGED <<version, nextQ, holder, pending, calling, offered, offerKey, answeredBy, shown, dismissed>>

\* `.answer` on the owner. 2025: answerElicitation(slot) answers whatever
\* question holds the slot now; a free slot is UnknownElicitation (dropped).
\* 2026: respond(handle) answers that call's round, or UnknownCall.
Deliver ==
    /\ posted.q # None
    /\ LET target == IF version = "2025" THEN holder[posted.key] ELSE posted.key
           ok == target # None /\ pending[target] /\ (Guard => target = posted.q)
       IN /\ IF ok
             THEN /\ answeredBy' = [answeredBy EXCEPT ![target] = posted.q]
                  /\ pending' = [pending EXCEPT ![target] = FALSE]
                  /\ holder' = IF version = "2025" THEN [holder EXCEPT ![posted.key] = None] ELSE holder
             ELSE UNCHANGED <<answeredBy, pending, holder>>
    /\ posted' = [q |-> None, key |-> 0]
    /\ UNCHANGED <<version, nextQ, calling, offered, offerKey, asking, askKey, shown, dismissed>>

\* The server withdraws q: notifications/cancelled for its request (2025),
\* which frees its slot. A shown question stays on screen. With the repair,
\* fx drops q if the call holds it unshown (dropWithdrawn); before it, that
\* stayed too. A 2026 round ends only with its call.
Withdraw(q) ==
    /\ version = "2025" /\ pending[q]
    /\ pending' = [pending EXCEPT ![q] = FALSE]
    /\ holder' = [s \in SlotIds |-> IF holder[s] = q THEN None ELSE holder[s]]
    /\ IF Guard /\ offered = q
         THEN offered' = None /\ offerKey' = 0
         ELSE UNCHANGED <<offered, offerKey>>
    /\ UNCHANGED <<version, nextQ, calling, asking, askKey, posted, answeredBy, shown, dismissed>>

\* The call ends (answered, cancelled, timed out): finish drops a question
\* it hadn't taken. A 2026 round ends with it. A question already shown
\* stays on screen until answered.
CallEnds ==
    /\ calling
    /\ calling' = FALSE
    /\ offered' = None /\ offerKey' = 0
    /\ pending' = IF version = "2026" THEN [q \in Qs |-> FALSE] ELSE pending
    /\ UNCHANGED <<version, nextQ, holder, asking, askKey, posted, answeredBy, shown, dismissed>>

Next ==
    \/ Ask \/ Take \/ UserAnswers \/ Deliver \/ CallEnds
    \/ \E q \in Qs : Withdraw(q)
    \/ UNCHANGED vars

Fairness == WF_vars(Take) /\ WF_vars(UserAnswers) /\ WF_vars(Deliver)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety the code keeps ----

\* Each question is answered at most once, by fx or by an answer the user gave.
AnsweredOnce == \A q \in Qs : answeredBy[q] # None => ~pending[q]

\* A question fx dismissed at once (no call could ask) is never shown.
DismissedNeverShown == \A q \in Qs : ~(shown[q] /\ dismissed[q])

\* One question at a time on screen, and the call holds at most one more.
OneOnScreen == asking # offered \/ asking = None

\* 2026 answers reach only the round the user saw: handles aren't reused.
AnswerReachesSeen2026 == version = "2026" => \A q \in Qs : answeredBy[q] \in {None, q}

\* ---- Stated safety (ElicitationRouting.findings.cfg) ----

\* An answer reaches only the question the user saw.
AnswerReachesSeenQuestion == \A q \in Qs : answeredBy[q] \in {None, q}

\* With the repair, a question the call holds unshown is one the server
\* still waits for, so a withdrawn one is never shown.
OfferedStillWaits == Guard => \A q \in Qs : offered = q => pending[q]

\* ---- Liveness ----

\* Every question the user sees gets an answer delivered, or is dropped.
ShownIsAnswered == \A q \in Qs : shown[q] ~> (asking # q /\ posted.q # q)
====
