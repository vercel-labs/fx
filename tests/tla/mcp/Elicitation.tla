---- MODULE Elicitation ----
\* U11 elicitation, client side, for one 2025 session: the server's
\* elicitation/create requests and the URL elicitations a -32042 error lists,
\* what the client hands the host, the one answer it sends for each request,
\* and the completion notifications of URL elicitations. Rules:
\* ELIC-01..ELIC-09.
\*
\* Each r in Reqs is one elicitation the server may start, once: a request
\* (origin "request", answered with a JSON-RPC response) or one listed in a
\* -32042 error (origin "required", never answered). Its mode is form or url,
\* and a url one may carry an elicitationId. The client declared the modes in
\* `declared`, fixed at Init; none at all when it declares no elicitation. One it can't read, in a mode it didn't declare,
\* or that finds MaxPending already with the host gets an error if it is a
\* request, and never reaches the host (ELIC-03). The host answers
\* what it was shown: accept (with content in form mode, which may fail the
\* schema), decline, or cancel. The server may cancel its own request,
\* the session may end, and a completion notification may name any
\* elicitation at any time. One that names a url elicitation the host still
\* holds is kept, and told the moment the host accepts it. The ghosts
\* record a broken rule when it breaks.
EXTENDS Naturals, FiniteSets

CONSTANTS Reqs, MaxPending

ASSUME Reqs \subseteq Nat /\ MaxPending \in Nat \ {0}

Modes == {"form", "url"}
Origins == {"request", "required"}
Actions == {"accept", "decline", "cancel"}
Phases == {"idle", "shown", "waiting", "done"}
\* What a request was answered with: "content" is a form accept with its content.
Answers == {"none", "error", "content", "accept", "decline", "cancel"}

VARIABLES
    phase,      \* [Reqs -> Phases]
    origin,     \* [Reqs -> Origins]
    mode,       \* [Reqs -> Modes]
    eid,        \* [Reqs -> BOOLEAN]: a url one carries an elicitationId
    sent,       \* [Reqs -> Answers]: the response sent for a request
    declared,   \* SUBSET Modes, fixed at Init: the modes the client declared
    early,      \* [Reqs -> BOOLEAN]: its completion came while the host held it
    \* ghosts
    sends,      \* [Reqs -> 0..2]: responses sent
    shownEver,  \* [Reqs -> BOOLEAN]: the host was shown it
    decided,    \* [Reqs -> Actions \cup {"none"}]: what the host answered
    withdrawn,  \* [Reqs -> BOOLEAN]: the host was told it is withdrawn
    told,       \* [Reqs -> 0..2]: completions the host was told of
    invalidSent \* content that failed the schema was sent

vars == <<phase, origin, mode, eid, sent, declared, early, sends, shownEver, decided, withdrawn, told, invalidSent>>

Pending == {r \in Reqs: phase[r] \in {"shown", "waiting"}}

TypeOK ==
    /\ phase \in [Reqs -> Phases]
    /\ origin \in [Reqs -> Origins]
    /\ mode \in [Reqs -> Modes]
    /\ eid \in [Reqs -> BOOLEAN]
    /\ sent \in [Reqs -> Answers]
    /\ declared \in SUBSET Modes
    /\ early \in [Reqs -> BOOLEAN]
    /\ sends \in [Reqs -> 0..2]
    /\ shownEver \in [Reqs -> BOOLEAN]
    /\ decided \in [Reqs -> Actions \cup {"none"}]
    /\ withdrawn \in [Reqs -> BOOLEAN]
    /\ told \in [Reqs -> 0..2]
    /\ invalidSent \in BOOLEAN

Init ==
    /\ phase = [r \in Reqs |-> "idle"]
    /\ origin = [r \in Reqs |-> "request"]
    /\ mode = [r \in Reqs |-> "form"]
    /\ eid = [r \in Reqs |-> FALSE]
    /\ sent = [r \in Reqs |-> "none"]
    /\ declared \in SUBSET Modes
    /\ early = [r \in Reqs |-> FALSE]
    /\ sends = [r \in Reqs |-> 0]
    /\ shownEver = [r \in Reqs |-> FALSE]
    /\ decided = [r \in Reqs |-> "none"]
    /\ withdrawn = [r \in Reqs |-> FALSE]
    /\ told = [r \in Reqs |-> 0]
    /\ invalidSent = FALSE

\* The server starts elicitation r. A -32042 error lists only url ones with
\* an elicitationId, and only url ones carry one.
Ask(r, o, m, e, readable) ==
    /\ phase[r] = "idle"
    /\ o = "required" => m = "url" /\ e
    /\ m = "form" => ~e
    /\ origin' = [origin EXCEPT ![r] = o]
    /\ mode' = [mode EXCEPT ![r] = m]
    /\ eid' = [eid EXCEPT ![r] = e]
    /\ IF readable /\ m \in declared /\ Cardinality(Pending) < MaxPending
         THEN /\ phase' = [phase EXCEPT ![r] = "shown"]
              /\ shownEver' = [shownEver EXCEPT ![r] = TRUE]
              /\ UNCHANGED <<sent, sends>>
         ELSE /\ phase' = [phase EXCEPT ![r] = "done"]
              /\ UNCHANGED shownEver
              /\ IF o = "request"
                   THEN /\ sent' = [sent EXCEPT ![r] = "error"]
                        /\ sends' = [sends EXCEPT ![r] = @ + 1]
                   ELSE UNCHANGED <<sent, sends>>
    /\ UNCHANGED <<declared, early, decided, withdrawn, told, invalidSent>>

\* The host answers what it holds. Form content that fails the schema is
\* refused back to the host, and nothing changes. An accepted url one
\* with an elicitationId waits for its completion, unless it already came:
\* then the host is told now.
Answer(r, a, valid) ==
    /\ phase[r] = "shown"
    /\ IF a = "accept" /\ mode[r] = "form" /\ ~valid
         THEN UNCHANGED vars
         ELSE /\ decided' = [decided EXCEPT ![r] = a]
              /\ IF origin[r] = "request"
                   THEN /\ sent' = [sent EXCEPT ![r] = IF a = "accept" /\ mode[r] = "form" THEN "content" ELSE a]
                        /\ sends' = [sends EXCEPT ![r] = @ + 1]
                   ELSE UNCHANGED <<sent, sends>>
              /\ phase' = [phase EXCEPT ![r] = IF a = "accept" /\ mode[r] = "url" /\ eid[r] /\ ~early[r] THEN "waiting" ELSE "done"]
              /\ told' = [told EXCEPT ![r] = IF a = "accept" /\ mode[r] = "url" /\ eid[r] /\ early[r] THEN @ + 1 ELSE @]
              /\ invalidSent' = (invalidSent \/ (a = "accept" /\ mode[r] = "form" /\ ~valid))
              /\ UNCHANGED <<origin, mode, eid, declared, early, shownEver, withdrawn>>

\* The server cancels its own request (2025 notifications/cancelled): one the
\* host still holds is withdrawn, and any other cancel is ignored.
ServerCancel(r) ==
    IF phase[r] = "shown" /\ origin[r] = "request"
      THEN /\ phase' = [phase EXCEPT ![r] = "done"]
           /\ withdrawn' = [withdrawn EXCEPT ![r] = TRUE]
           /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, told, invalidSent>>
      ELSE UNCHANGED vars

\* The session ends (a new initialize, a DELETE, detection again): what the
\* host holds is withdrawn, and what waits for its completion is forgotten,
\* so no answer reaches another session.
SessionEnd ==
    /\ Pending # {}
    /\ phase' = [r \in Reqs |-> IF r \in Pending THEN "done" ELSE phase[r]]
    /\ withdrawn' = [r \in Reqs |-> withdrawn[r] \/ phase[r] = "shown"]
    /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, told, invalidSent>>

\* notifications/elicitation/complete naming r's elicitationId: one the host
\* accepted and that still waits is told, once (ELIC-08). One still with
\* the host is kept for its acceptance. One never started or already
\* over is ignored.
Complete(r) ==
    CASE phase[r] = "waiting" ->
           /\ phase' = [phase EXCEPT ![r] = "done"]
           /\ told' = [told EXCEPT ![r] = @ + 1]
           /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, withdrawn, invalidSent>>
      [] phase[r] = "shown" /\ mode[r] = "url" /\ eid[r] ->
           /\ early' = [early EXCEPT ![r] = TRUE]
           /\ UNCHANGED <<phase, origin, mode, eid, sent, declared, sends, shownEver, decided, withdrawn, told, invalidSent>>
      [] OTHER -> UNCHANGED vars

Next ==
    \E r \in Reqs:
        \/ \E o \in Origins, m \in Modes, e, readable \in BOOLEAN: Ask(r, o, m, e, readable)
        \/ \E a \in Actions, valid \in BOOLEAN: Answer(r, a, valid)
        \/ ServerCancel(r)
        \/ Complete(r)
        \/ SessionEnd

\* The host answers, in time, with content that passes.
Spec == Init /\ [][Next]_vars /\ \A r \in Reqs: WF_vars(\E a \in Actions: Answer(r, a, TRUE))

\* ---- properties ----

\* Every request gets at most one response.
AnsweredOnce == \A r \in Reqs: sends[r] <= 1

\* The host is never shown a mode the client didn't declare (ELIC-03), and
\* such a request is answered with an error.
ModeGate ==
    \A r \in Reqs:
        /\ shownEver[r] => mode[r] \in declared
        /\ (phase[r] = "done" /\ origin[r] = "request" /\ mode[r] \notin declared) => sent[r] = "error"

\* Every answer but an error is the host's own.
HostDecides ==
    \A r \in Reqs: sent[r] \in Actions \cup {"content"} => decided[r] = IF sent[r] = "content" THEN "accept" ELSE sent[r]

\* Content goes only with a form accept, and a form accept always has it (ELIC-09).
ContentGate ==
    \A r \in Reqs:
        /\ sent[r] = "content" => mode[r] = "form"
        /\ sent[r] = "accept" => mode[r] = "url"

\* Content that fails the schema is never sent (ELIC-05).
ValidOnly == ~invalidSent

\* A withdrawn elicitation is never answered.
NothingAfterWithdraw == \A r \in Reqs: withdrawn[r] => sent[r] = "none" /\ decided[r] = "none"

\* The host hears of a completion once, and only for a url one it accepted (ELIC-08).
CompleteOnce == \A r \in Reqs: told[r] <= 1
CompleteOnlyAccepted == \A r \in Reqs: told[r] = 1 => decided[r] = "accept" /\ mode[r] = "url" /\ eid[r]
\* A completion that came first isn't lost once the host accepts.
EarlyCompletionTold == \A r \in Reqs: early[r] /\ decided[r] = "accept" => told[r] = 1

\* One listed in a -32042 error has no request to answer.
RequiredUnanswered == \A r \in Reqs: origin[r] = "required" => sends[r] = 0

\* The host never holds more than MaxPending.
Bounded == Cardinality(Pending) <= MaxPending

\* Whatever the host is shown leaves it: answered or withdrawn.
EveryElicitationEnds == \A r \in Reqs: phase[r] = "shown" ~> phase[r] \in {"waiting", "done"}
====
