------------------------------- MODULE McpCall -------------------------------
(***************************************************************************)
(* The `fx mcp call` bridge: how a running fx session takes MCP tool calls *)
(* from shell commands. It models the pure core `step(state, event)` in    *)
(* src/core/mcp_host/mcp_call.zig. The shell around it is                 *)
(* src/core/mcp_host/mcp_call_bridge.zig; design/FINISH.md lists what is   *)
(* still open.                                                             *)
(*                                                                         *)
(* Each core event is one action with the same name: Started, Stopped,     *)
(* OwnerAdded, OwnerRemoved, Lent, LendEnded, Request, Authorized,         *)
(* CallFinished, ReplyDone, and ClientGone. The environment acts through   *)
(* the values those events carry and through Crash:                        *)
(*   - a client can present any token: the current one, one revoked by a  *)
(*     restart or a command's end, or a forged one, and any version;       *)
(*   - every answer the shell owes can be late, duplicated, or name a      *)
(*     request that is gone or was never admitted (a garbage peer);        *)
(*   - a client can disconnect at any step, and a reply can be lost;       *)
(*   - the session can stop, and an owner's command can end, mid-call;     *)
(*   - the shell call that lends an owner its permission check can return, *)
(*     and a later one can lend again, at any step;                        *)
(*   - the process can crash at any step, which drops all core state.      *)
(* A second process is not modeled: the core lives in one fx process, and  *)
(* a second fx process has its own bridge, socket, and tokens.             *)
(*                                                                         *)
(* An owner is one command fx's shell runs, from its shell call until its  *)
(* process ends. It is lent while a shell call of its agent (the run call  *)
(* that started it, or an interact that watches it) lends it that call's   *)
(* permission check and MCP call. A request of an owner that no call lends *)
(* to waits.                                                               *)
(*                                                                         *)
(* open, registered, next, and entries are `abstract(state)` in the code.  *)
(* out is the effects the step returned, and act is the event the step     *)
(* took, recorded so the laws can name it. Tokens are names here; in the   *)
(* code they are 32 random bytes the shell makes.                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxInFlight,   \* requests the core holds at once, abandoned ones included
    MaxIds         \* the model's bound on requests per process

Owners == {"main", "child"}
Tokens == {"t1", "t2"}
Presented == Tokens \cup {"forged"}
Versions == {1, 2}
Ids == 0..(MaxIds - 1)
Stages == {"waiting", "authorizing", "calling", "replying", "abandoned_auth", "abandoned_call"}
Outcomes == {"ok", "tool_error", "failed"}
ReplyOutcomes == Outcomes \cup {"denied"}
Reasons == {"closed", "unauthorized", "unsupported_version", "busy"}
Drops == {"stale", "result_dropped", "reply_lost"}

Entries == [id: Ids, owner: Owners, stage: Stages]
Registrations == [owner: Owners, token: Tokens, lent: BOOLEAN]

Effects == [kind: {"refuse"}, reason: Reasons]
           \cup [kind: {"authorize", "wait", "call"}, id: Ids, owner: Owners]
           \cup [kind: {"withdraw", "cancel"}, id: Ids]
           \cup [kind: {"reply"}, id: Ids, outcome: ReplyOutcomes]
           \cup [kind: {"log"}, id: Ids, what: Drops]

Acts == [name: {"Init", "Stopped", "Crash"}]
        \cup [name: {"Started"}, token: Tokens]
        \cup [name: {"OwnerAdded"}, owner: Owners, token: Tokens]
        \cup [name: {"OwnerRemoved", "Lent", "LendEnded"}, owner: Owners]
        \cup [name: {"Request"}, token: Presented, version: Versions]
        \cup [name: {"Authorized"}, id: Ids, allow: BOOLEAN]
        \cup [name: {"CallFinished"}, id: Ids, outcome: Outcomes]
        \cup [name: {"ReplyDone"}, id: Ids, delivered: BOOLEAN]
        \cup [name: {"ClientGone"}, id: Ids]

VARIABLES open, registered, next, entries, out, act

vars == <<open, registered, next, entries, out, act>>

EntryIds == {e.id : e \in entries}
Entry(i) == CHOOSE e \in entries : e.id = i
Holds(i, stages) == i \in EntryIds /\ Entry(i).stage \in stages
InUse == {r.token : r \in registered}
RegOwners == {r.owner : r \in registered}
IsLent(o) == \E r \in registered : r.owner = o /\ r.lent
SetLent(o, b) == {IF r.owner = o THEN [r EXCEPT !.lent = b] ELSE r : r \in registered}
\* Only a planted bug admits a token nobody holds; it then acts as main, so
\* AdmitOnlyValid reports the bug instead of TLC failing on an empty CHOOSE.
TokenOwner(t) == IF \E r \in registered : r.token = t
                 THEN (CHOOSE r \in registered : r.token = t).owner
                 ELSE "main"

SetStage(i, s) == {IF e.id = i THEN [e EXCEPT !.stage = s] ELSE e : e \in entries}
Remove(i) == {e \in entries : e.id # i}
Log(i, what) == [kind |-> "log", id |-> i, what |-> what]

\* Work in flight is let go: a waiting prompt is withdrawn and a running call
\* cancelled. Each keeps its slot until the shell reports it ended. A request
\* still waiting for a lender is withdrawn too: the shell answers it without
\* a check.
Abandon(e) == CASE e.stage \in {"waiting", "authorizing"} -> [e EXCEPT !.stage = "abandoned_auth"]
                [] e.stage = "calling" -> [e EXCEPT !.stage = "abandoned_call"]
                [] OTHER -> e
LetGo(e) == CASE e.stage \in {"waiting", "authorizing"} -> {[kind |-> "withdraw", id |-> e.id]}
              [] e.stage = "calling" -> {[kind |-> "cancel", id |-> e.id]}
              [] OTHER -> {}
AbandonAll(S) ==
    /\ entries' = {IF e \in S THEN Abandon(e) ELSE e : e \in entries}
    /\ out' = UNION {LetGo(e) : e \in S}

\* `refusal`: the first check a request fails, or "none".
FirstRefusal(t, v) ==
    CASE ~open -> "closed"
      [] t \notin InUse -> "unauthorized"
      [] v # 1 -> "unsupported_version"
      [] Cardinality(entries) >= MaxInFlight -> "busy"
      [] OTHER -> "none"

Init ==
    /\ open = FALSE
    /\ registered = {}
    /\ next = 0
    /\ entries = {}
    /\ out = {}
    /\ act = [name |-> "Init"]

\* The shell opened the bridge for a session and made the session's token.
\* Requests of an earlier session in this process may still be draining.
Started(t) ==
    /\ act' = [name |-> "Started", token |-> t]
    /\ out' = {}
    /\ IF open
       THEN UNCHANGED <<open, registered>>
       ELSE /\ open' = TRUE
            /\ registered' = {[owner |-> "main", token |-> t, lent |-> TRUE]}
    /\ UNCHANGED <<next, entries>>

\* The session ends (quit, /new, /resume): every token is revoked and all
\* work in flight is let go.
Stopped ==
    /\ act' = [name |-> "Stopped"]
    /\ IF open
       THEN /\ open' = FALSE
            /\ registered' = {}
            /\ AbandonAll(entries)
       ELSE /\ out' = {}
            /\ UNCHANGED <<open, registered, entries>>
    /\ UNCHANGED next

\* A command starts with its own token, lent by the shell call that runs it.
OwnerAdded(o, t) ==
    /\ act' = [name |-> "OwnerAdded", owner |-> o, token |-> t]
    /\ out' = {}
    /\ IF open /\ o \notin RegOwners /\ t \notin InUse
       THEN registered' = registered \cup {[owner |-> o, token |-> t, lent |-> TRUE]}
       ELSE UNCHANGED registered
    /\ UNCHANGED <<open, next, entries>>

\* A command ends: its token is revoked and its work let go. The session's
\* own owner leaves only with Stopped.
OwnerRemoved(o) ==
    /\ act' = [name |-> "OwnerRemoved", owner |-> o]
    /\ IF o # "main" /\ o \in RegOwners
       THEN /\ registered' = {r \in registered : r.owner # o}
            /\ AbandonAll({e \in entries : e.owner = o})
       ELSE /\ out' = {}
            /\ UNCHANGED <<registered, entries>>
    /\ UNCHANGED <<open, next>>

\* A shell call lends an owner its permission check and MCP call: an interact
\* that watches the owner's command. Each request the owner holds waiting
\* moves on to the check. The session's own owner is always lent, since no
\* command holds its token.
Lent(o) ==
    /\ act' = [name |-> "Lent", owner |-> o]
    /\ IF o # "main" /\ o \in RegOwners /\ ~IsLent(o)
       THEN LET waiting == {e \in entries : e.owner = o /\ e.stage = "waiting"} IN
            /\ registered' = SetLent(o, TRUE)
            /\ entries' = {IF e \in waiting THEN [e EXCEPT !.stage = "authorizing"] ELSE e : e \in entries}
            /\ out' = {[kind |-> "authorize", id |-> e.id, owner |-> o] : e \in waiting}
       ELSE /\ out' = {}
            /\ UNCHANGED <<registered, entries>>
    /\ UNCHANGED <<open, next>>

\* The lending shell call returns while the command still runs. Work it
\* already started keeps its lender until that work ends, because the shell
\* waits for it; later requests wait.
LendEnded(o) ==
    /\ act' = [name |-> "LendEnded", owner |-> o]
    /\ out' = {}
    /\ IF o # "main" /\ o \in RegOwners /\ IsLent(o)
       THEN registered' = SetLent(o, FALSE)
       ELSE UNCHANGED registered
    /\ UNCHANGED <<open, next, entries>>

\* A client sent one complete request line. A request of an owner no shell
\* call lends to waits for one, with no permission check yet.
Request(t, v) ==
    /\ next < MaxIds
    /\ act' = [name |-> "Request", token |-> t, version |-> v]
    /\ LET reason == FirstRefusal(t, v) IN
       IF reason # "none"
       THEN /\ out' = {[kind |-> "refuse", reason |-> reason]}
            /\ UNCHANGED <<open, registered, next, entries>>
       ELSE LET o == TokenOwner(t)
                e == [id |-> next, owner |-> o, stage |-> IF IsLent(o) THEN "authorizing" ELSE "waiting"] IN
            /\ entries' = entries \cup {e}
            /\ next' = next + 1
            /\ out' = IF IsLent(o) THEN {[kind |-> "authorize", id |-> e.id, owner |-> e.owner]}
                                  ELSE {[kind |-> "wait", id |-> e.id, owner |-> e.owner]}
            /\ UNCHANGED <<open, registered>>

\* The permission check answered.
Authorized(i, allow) ==
    /\ act' = [name |-> "Authorized", id |-> i, allow |-> allow]
    /\ CASE Holds(i, {"authorizing"}) ->
              IF allow
              THEN /\ entries' = SetStage(i, "calling")
                   /\ out' = {[kind |-> "call", id |-> i, owner |-> Entry(i).owner]}
              ELSE /\ entries' = SetStage(i, "replying")
                   /\ out' = {[kind |-> "reply", id |-> i, outcome |-> "denied"]}
         [] Holds(i, {"abandoned_auth"}) ->
              /\ entries' = Remove(i)
              /\ out' = {}
         [] OTHER ->
              /\ entries' = entries
              /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>

\* The MCP call ended. A call cancelled before it finished ends "failed".
CallFinished(i, o) ==
    /\ act' = [name |-> "CallFinished", id |-> i, outcome |-> o]
    /\ CASE Holds(i, {"calling"}) ->
              /\ entries' = SetStage(i, "replying")
              /\ out' = {[kind |-> "reply", id |-> i, outcome |-> o]}
         [] Holds(i, {"abandoned_call"}) ->
              /\ entries' = Remove(i)
              /\ out' = IF o = "failed" THEN {} ELSE {Log(i, "result_dropped")}
         [] OTHER ->
              /\ entries' = entries
              /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>

\* The shell finished writing a reply, or could not.
ReplyDone(i, delivered) ==
    /\ act' = [name |-> "ReplyDone", id |-> i, delivered |-> delivered]
    /\ IF Holds(i, {"replying"})
       THEN /\ entries' = Remove(i)
            /\ out' = IF delivered THEN {} ELSE {Log(i, "reply_lost")}
       ELSE /\ entries' = entries
            /\ out' = {Log(i, "stale")}
    /\ UNCHANGED <<open, registered, next>>

\* The client's connection closed: the command ended or was cancelled.
ClientGone(i) ==
    /\ act' = [name |-> "ClientGone", id |-> i]
    /\ IF Holds(i, {"waiting", "authorizing", "calling"})
       THEN /\ entries' = {IF e.id = i THEN Abandon(e) ELSE e : e \in entries}
            /\ out' = LetGo(Entry(i))
       ELSE /\ entries' = entries
            /\ out' = {}
    /\ UNCHANGED <<open, registered, next>>

\* The process dies; the next one starts from the core's zero state. Its
\* clients' connections die with it.
Crash ==
    /\ act' = [name |-> "Crash"]
    /\ open' = FALSE
    /\ registered' = {}
    /\ next' = 0
    /\ entries' = {}
    /\ out' = {}

Next ==
    \/ \E t \in Tokens : Started(t)
    \/ Stopped
    \/ \E o \in Owners, t \in Tokens : OwnerAdded(o, t)
    \/ \E o \in Owners : OwnerRemoved(o)
    \/ \E o \in Owners : Lent(o)
    \/ \E o \in Owners : LendEnded(o)
    \/ \E t \in Presented, v \in Versions : Request(t, v)
    \/ \E i \in Ids, a \in BOOLEAN : Authorized(i, a)
    \/ \E i \in Ids, o \in Outcomes : CallFinished(i, o)
    \/ \E i \in Ids, d \in BOOLEAN : ReplyDone(i, d)
    \/ \E i \in Ids : ClientGone(i)
    \/ Crash

\* What the shell owes for each request it holds: a permission answer (a
\* withdrawn prompt answers too), the end of each call it started (a
\* cancelled call ends too), and the end of each reply it writes.
Answer(i) == Holds(i, {"authorizing", "abandoned_auth"}) /\ \E a \in BOOLEAN : Authorized(i, a)
Finish(i) == Holds(i, {"calling", "abandoned_call"}) /\ \E o \in Outcomes : CallFinished(i, o)
Deliver(i) == Holds(i, {"replying"}) /\ \E d \in BOOLEAN : ReplyDone(i, d)
\* A waiting request moves on once its agent watches the command again. The
\* model assumes the agent does, or that the command or its client ends,
\* which lets the request go instead.
Resume(i) == Holds(i, {"waiting"}) /\ Lent(Entry(i).owner)

Spec == Init /\ [][Next]_vars /\ \A i \in Ids : WF_vars(Answer(i)) /\ WF_vars(Finish(i)) /\ WF_vars(Deliver(i)) /\ WF_vars(Resume(i))

-----------------------------------------------------------------------------
(* Laws. DESIGN.md names each one and where it is enforced. Each is stated *)
(* on its own terms, not through the helpers the actions use, so a planted *)
(* bug in a helper cannot hide from the law that checks it.                *)

Live == {"authorizing", "calling"}
Advances == {<<s, s>> : s \in Stages}
            \cup {<<"waiting", "authorizing">>, <<"waiting", "abandoned_auth">>,
                  <<"authorizing", "calling">>, <<"authorizing", "replying">>,
                  <<"authorizing", "abandoned_auth">>, <<"calling", "replying">>,
                  <<"calling", "abandoned_call">>}
\* The events whose arrival ends an entry, by the stage it ends from.
Ends == {<<"Authorized", "abandoned_auth">>, <<"CallFinished", "abandoned_call">>, <<"ReplyDone", "replying">>}
\* The events each stage waits for.
Expected == {<<"Authorized", "authorizing">>, <<"Authorized", "abandoned_auth">>,
             <<"CallFinished", "calling">>, <<"CallFinished", "abandoned_call">>,
             <<"ReplyDone", "replying">>, <<"ClientGone", "waiting">>, <<"ClientGone", "authorizing">>,
             <<"ClientGone", "calling">>}
IdEvents == {"Authorized", "CallFinished", "ReplyDone", "ClientGone"}

TypeOK ==
    /\ open \in BOOLEAN
    /\ registered \subseteq Registrations
    /\ next \in 0..MaxIds
    /\ entries \subseteq Entries
    /\ out \subseteq Effects
    /\ act \in Acts

\* L13: the table, the step's effects, and the registrations are bounded and
\* keyed: one entry per id, one token per owner, one owner per token.
Bounded ==
    /\ Cardinality(entries) <= MaxInFlight
    /\ Cardinality(out) <= MaxInFlight
    /\ Cardinality(out) > 1 => act.name \in {"Stopped", "OwnerRemoved", "Lent"}
    /\ \A i \in EntryIds : Cardinality({e \in entries : e.id = i}) = 1
    /\ \A o \in Owners : Cardinality({r \in registered : r.owner = o}) <= 1
    /\ \A t \in Tokens : Cardinality({r \in registered : r.token = t}) <= 1

\* L3: every id the table holds was issued in this process.
IdsBelowNext == \A i \in EntryIds : i < next

\* L8: authorize, wait, and call effects carry the owner their request was
\* admitted for.
EffectsCarryEntryOwner ==
    \A e \in out : e.kind \in {"authorize", "wait", "call"} =>
        \E x \in entries : x.id = e.id /\ x.owner = e.owner

\* L9: no prompt waits and no call runs for an owner whose token is revoked.
LiveWorkHasOwner == \A x \in entries : x.stage \in Live => x.owner \in {r.owner : r \in registered}

\* L10: a closed bridge holds no token and starts no prompt or call.
ClosedIsQuiet == ~open => (registered = {} /\ \A e \in out : e.kind \notin {"authorize", "call"})

\* L14: a new process starts from nothing.
CrashResets == act.name \in {"Init", "Crash"} => (~open /\ registered = {} /\ next = 0 /\ entries = {} /\ out = {})

\* L1: a request is admitted only on an open bridge, with a token in force,
\* the supported version, and a free slot. Its entry waits for the permission
\* check, as the token's owner, or for a lender when no shell call lends to
\* that owner.
AdmitOnlyValid ==
    [][\A i \in {e.id : e \in entries'} \ EntryIds :
          /\ act'.name = "Request"
          /\ open
          /\ \E r \in registered : r.token = act'.token
          /\ act'.version = 1
          /\ Cardinality(entries) < MaxInFlight
          /\ \E e \in entries' : /\ e.id = i
                                 /\ \E r \in registered : /\ r.token = act'.token
                                                         /\ r.owner = e.owner
                                                         /\ e.stage = IF r.lent THEN "authorizing" ELSE "waiting"]_vars

\* L2: a refused request changes nothing and gets one reason, the first check
\* it failed in the order closed, unauthorized, version, busy. A client without
\* a token in force learns nothing about versions or load.
RefusalsAreQuiet ==
    [][(\E e \in out' : e.kind = "refuse") =>
          /\ act'.name = "Request"
          /\ Cardinality(out') = 1
          /\ UNCHANGED <<open, registered, next, entries>>
          /\ LET reason == (CHOOSE e \in out' : TRUE).reason
                 known == \E r \in registered : r.token = act'.token
             IN /\ (reason = "closed") <=> ~open
                /\ (reason = "unauthorized") <=> (open /\ ~known)
                /\ (reason = "unsupported_version") => (open /\ known /\ act'.version # 1)
                /\ (reason = "busy") => (open /\ known /\ act'.version = 1 /\ Cardinality(entries) >= MaxInFlight)]_vars

\* L3: each admission takes the next id, which no request holds, and only an
\* admission or a new process moves it.
FreshIds ==
    [][LET admitted == {e.id : e \in entries'} \ EntryIds IN
       /\ admitted # {} => (admitted = {next} /\ next' = next + 1)
       /\ next' # next => (act'.name = "Crash" \/ admitted = {next})]_vars

\* L4: a call starts only when the permission check allows a request that is
\* waiting for it, on that step, and the request moves to calling. With
\* StagesOnlyAdvance and FreshIds, each request id runs at most one call.
CallOnlyFromAuthorizing ==
    [][\A e \in out' : e.kind = "call" =>
          /\ act'.name = "Authorized" /\ act'.id = e.id /\ act'.allow
          /\ \E x \in entries : x.id = e.id /\ x.stage = "authorizing"
          /\ \E y \in entries' : y.id = e.id /\ y.stage = "calling"]_vars

\* L5: a request's stage only moves forward, its owner never changes, and it
\* leaves the table only on the event that ends it, or with its process.
StagesOnlyAdvance ==
    [][/\ \A x \in entries, y \in entries' : x.id = y.id => (<<x.stage, y.stage>> \in Advances /\ x.owner = y.owner)
       /\ \A x \in entries : x.id \notin {e.id : e \in entries'} =>
              (act'.name = "Crash" \/ (act'.name \in IdEvents /\ act'.id = x.id /\ <<act'.name, x.stage>> \in Ends))]_vars

\* L6: a request gets a reply only on the step it starts replying, so at most
\* once.
OneReplyPerRequest ==
    [][\A e \in out' : e.kind = "reply" =>
          /\ \E x \in entries : x.id = e.id /\ x.stage \in Live
          /\ \E y \in entries' : y.id = e.id /\ y.stage = "replying"]_vars

\* L7: the reply says what happened: the call's own outcome, or a denial.
ReplyMatchesOutcome ==
    [][\A e \in out' : e.kind = "reply" =>
          \/ act'.name = "CallFinished" /\ act'.id = e.id /\ e.outcome = act'.outcome
          \/ act'.name = "Authorized" /\ act'.id = e.id /\ ~act'.allow /\ e.outcome = "denied"]_vars

\* L11: an answer for a request that is gone, or that its stage does not wait
\* for (late, duplicated, or garbage), changes nothing and is logged. A
\* disconnect after the work ended is expected and says nothing.
StaleIsQuiet ==
    [][(act'.name \in IdEvents /\ ~\E x \in entries : x.id = act'.id /\ <<act'.name, x.stage>> \in Expected) =>
          /\ UNCHANGED <<open, registered, next, entries>>
          /\ out' = IF act'.name = "ClientGone" THEN {} ELSE {[kind |-> "log", id |-> act'.id, what |-> "stale"]}]_vars

\* L12: user data the core drops is logged with its request id: a result for
\* a client that is gone, and a reply that could not be written.
DroppedStateIsLogged ==
    [][/\ (act'.name = "CallFinished" /\ act'.outcome # "failed" /\ \E x \in entries : x.id = act'.id /\ x.stage = "abandoned_call")
             => [kind |-> "log", id |-> act'.id, what |-> "result_dropped"] \in out'
       /\ (act'.name = "ReplyDone" /\ ~act'.delivered /\ \E x \in entries : x.id = act'.id /\ x.stage = "replying")
             => [kind |-> "log", id |-> act'.id, what |-> "reply_lost"] \in out']_vars

\* L15: every request the core admits leaves the table, given the answers the
\* shell owes and a lender for each waiting request (Resume).
Drained == \A i \in Ids : (i \in EntryIds) ~> (i \notin EntryIds)

\* L16: a permission check starts only for an owner a shell call lends to,
\* on its admission or on the lend, and its request then waits for the check.
AuthorizeOnlyWhileLent ==
    [][\A e \in out' : e.kind = "authorize" =>
          /\ act'.name \in {"Request", "Lent"}
          /\ \E r \in registered' : r.owner = e.owner /\ r.lent
          /\ \E y \in entries' : y.id = e.id /\ y.stage = "authorizing"]_vars

\* L17: a request waits for a lender only while its owner is registered and
\* no shell call lends to it: a lend moves it on, and the owner's end lets it
\* go.
WaitingOnlyUnlent ==
    \A x \in entries : x.stage = "waiting" => \E r \in registered : r.owner = x.owner /\ ~r.lent

\* L18: a command's owner is lent from the step a shell call lends to it, or
\* registers it, until the step that call returns; nothing else changes it.
\* The session's own owner is always lent.
LendFollowsLender ==
    [][\A r \in registered, s \in registered' :
          (r.owner = s.owner /\ r.token = s.token) =>
              s.lent = CASE r.owner = "main" -> TRUE
                         [] act'.name = "Lent" /\ act'.owner = r.owner -> TRUE
                         [] act'.name = "LendEnded" /\ act'.owner = r.owner -> FALSE
                         [] OTHER -> r.lent]_vars
=============================================================================
