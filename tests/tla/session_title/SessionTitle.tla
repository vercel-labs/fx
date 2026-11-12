---------------------------- MODULE SessionTitle ----------------------------
(***************************************************************************)
(* Session title generation and the model list while other fx processes   *)
(* share and refresh the same sign-in.                                    *)
(*                                                                         *)
(* fx asks a small model for a title on a session's first prompt           *)
(* (src/core/session/session_title_generation.zig) and loads the model     *)
(* list in the background (src/core/app/model_cache_runtime.zig). Both     *)
(* used to send the token the app held in memory. When another fx refreshed *)
(* the shared fx login, that token could be rejected while the store       *)
(* already held a newer one: the title request gave up after one 401 and   *)
(* the model list fell back to public models. The title gate also read the *)
(* in-memory history, which an interrupted first turn reaches only after   *)
(* the next prompt starts, so a second prompt could title the session.     *)
(*                                                                         *)
(* The design: a request sends the stored token when the store holds this  *)
(* sign-in's team, and the token in memory otherwise. After a 401 it sends *)
(* once more only with a stored token of this sign-in that replaced the    *)
(* rejected one. It never refreshes the sign-in itself: only the main turn *)
(* does, because every refresh rotates the login all fx processes share.   *)
(* A static key is never sent twice. The session records that a title     *)
(* request started, and the gate checks that record.                       *)
(*                                                                         *)
(* Tokens are versions: the store holds one, the gateway accepts a set,    *)
(* and the app's memory holds one. Other fx processes refresh the login    *)
(* (a new version, the old one kept or revoked) or sign in to another      *)
(* team, the gateway may stop accepting the stored token, and the main     *)
(* turn may adopt the stored token into memory.                            *)
(*                                                                         *)
(* Bug = "none" is the design. "today" is fx before it. Every other value  *)
(* plants one defect, and check.sh names the rule that must catch it.      *)
(* tests/tla/drivers/session_title/driver.ts runs the built fx along this  *)
(* model and has TLC check each run with SessionTitleTrace.tla.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Refreshable,     \* TRUE: fx login or a subscription; FALSE: a static key
    MaxRotations,    \* refreshes other fx processes may make
    MaxRevocations,  \* times the gateway may stop accepting the stored token
    OtherTeam,       \* TRUE: another fx process may sign in to another team once
    Bug

Bugs == {"none", "today", "no-reload", "no-replay", "double-replay",
         "background-refresh", "authority-unchecked", "replay-static-key",
         "history-gate", "catalog-no-reload", "catalog-no-replay"}

ASSUME /\ Refreshable \in BOOLEAN
       /\ MaxRotations \in Nat
       /\ MaxRevocations \in Nat
       /\ OtherTeam \in BOOLEAN
       /\ Bug \in Bugs

VARIABLES
    store,        \* version of the token in the credential store
    storeTeam,    \* "app": the store holds this sign-in's team; "other": another's
    accepted,     \* versions the gateway accepts
    memory,       \* version the app holds in memory, always this sign-in's
    rotations,    \* refreshes other fx processes made
    revocations,  \* stored tokens the gateway stopped accepting
    refreshes,    \* refreshes a background request made itself
    turn,         \* the first turn: "none", "running", "stopped", "committed"
    prompts,      \* prompts submitted
    attempted,    \* the session's record that a title request started
    starts,       \* title requests started
    title,        \* the title request
    catalog       \* the model list load

vars == <<store, storeTeam, accepted, memory, rotations, revocations,
          refreshes, turn, prompts, attempted, starts, title, catalog>>

envVars == <<store, storeTeam, accepted, memory, rotations, revocations, refreshes>>

(* One background request. sends is every request it made to the gateway,  *)
(* in order, with the token it carried, that token's team, and whether the *)
(* gateway took it. read, readTeam, and readMemory are the store, its      *)
(* team, and the memory when the request began. noReplacement is whether  *)
(* the store held no other token of this sign-in after a 401.             *)
Idle == [phase |-> "idle", prompt |-> 0, tok |-> 0, team |-> "app",
         read |-> 0, readTeam |-> "app", readMemory |-> 0,
         rejected |-> 0, sends |-> <<>>, noReplacement |-> FALSE,
         result |-> "none"]

Phases == {"idle", "reading", "sending", "checking", "done"}

-----------------------------------------------------------------------------
(* What each variant does.                                                 *)

TitleReadsStore == Bug \notin {"today", "no-reload"}
CatalogReadsStore == Bug \notin {"today", "catalog-no-reload"}
ChecksTeam == Bug # "authority-unchecked"
GateUsesRecord == Bug \notin {"today", "history-gate"}

(* Whether a request that has made n requests and was just rejected looks  *)
(* for another token.                                                      *)
TitleReplays(n) ==
    CASE Bug \in {"today", "no-replay"} -> FALSE
      [] Bug = "double-replay" -> Refreshable /\ n <= 2
      [] Bug = "replay-static-key" -> n = 1
      [] OTHER -> Refreshable /\ n = 1

CatalogReplays(n) ==
    CASE Bug \in {"today", "catalog-no-replay"} -> FALSE
      [] OTHER -> Refreshable /\ n = 1

(* The stored token may carry this request: the store holds its team.     *)
StoreUsable == storeTeam = "app" \/ ~ChecksTeam

-----------------------------------------------------------------------------
(* Steps of one request, shared by the title and the model list.           *)

Read(r, fromStore) ==
    LET useStore == fromStore /\ StoreUsable
    IN  [r EXCEPT !.phase = "sending",
                  !.tok = IF useStore THEN store ELSE memory,
                  !.team = IF useStore THEN storeTeam ELSE "app",
                  !.read = store, !.readTeam = storeTeam, !.readMemory = memory]

Send(r, replays) ==
    LET ok == r.tok \in accepted
        log == Append(r.sends, [tok |-> r.tok, team |-> r.team, ok |-> ok])
    IN  IF ok
        THEN [r EXCEPT !.phase = "done", !.sends = log, !.result = "ok"]
        ELSE IF replays
             THEN [r EXCEPT !.phase = "checking", !.sends = log, !.rejected = r.tok]
             ELSE [r EXCEPT !.phase = "done", !.sends = log, !.result = "failed"]

(* After a 401: send once more with a stored token of this sign-in that    *)
(* replaced the rejected one, or give up.                                  *)
Replaced(r) == store # r.rejected /\ StoreUsable

Recheck(r) ==
    IF Replaced(r)
    THEN [r EXCEPT !.phase = "sending", !.tok = store, !.team = storeTeam]
    ELSE IF Bug = "replay-static-key"
         THEN [r EXCEPT !.phase = "sending"]
         ELSE [r EXCEPT !.phase = "done", !.result = "failed", !.noReplacement = TRUE]

(* The planted defect "background-refresh": a request whose store still    *)
(* holds the rejected token refreshes the shared login itself.             *)
RefreshesItself(r) == Bug = "background-refresh" /\ Refreshable /\ ~Replaced(r)

RecheckStep(r) ==
    IF RefreshesItself(r)
    THEN /\ store' = store + 1
         /\ storeTeam' = "app"
         /\ accepted' = accepted \cup {store + 1}
         /\ refreshes' = refreshes + 1
    ELSE UNCHANGED <<store, storeTeam, accepted, refreshes>>

RecheckResult(r) ==
    IF RefreshesItself(r)
    THEN [r EXCEPT !.phase = "sending", !.tok = store + 1, !.team = "app"]
    ELSE Recheck(r)

-----------------------------------------------------------------------------
Init ==
    /\ store = 1
    /\ storeTeam = "app"
    /\ accepted = {1}
    /\ memory = 1
    /\ rotations = 0
    /\ revocations = 0
    /\ refreshes = 0
    /\ turn = "none"
    /\ prompts = 0
    /\ attempted = FALSE
    /\ starts = 0
    /\ title = Idle
    /\ catalog = Idle

(* The prompt-submit gate (src/core/app/app_session_runtime.zig            *)
(* maybeStartSessionTitleGeneration).                                      *)
Gate ==
    /\ title.result # "ok"                    \* no title yet
    /\ turn # "committed"                     \* the in-memory history is empty
    /\ title.phase \in {"idle", "done"}       \* no title request running
    /\ GateUsesRecord => ~attempted

StartTitle(n) ==
    IF Gate
    THEN /\ title' = [Idle EXCEPT !.phase = "reading", !.prompt = n]
         /\ attempted' = TRUE
         /\ starts' = starts + 1
    ELSE UNCHANGED <<title, attempted, starts>>

SubmitFirstPrompt ==
    /\ prompts = 0
    /\ prompts' = 1
    /\ turn' = "running"
    /\ StartTitle(1)
    /\ UNCHANGED <<envVars, catalog>>

(* The first turn ends or the user interrupts it.                          *)
TurnStops ==
    /\ turn = "running"
    /\ turn' = "stopped"
    /\ UNCHANGED <<envVars, prompts, attempted, starts, title, catalog>>

(* The stopped turn reaches the in-memory history.                         *)
CommitTurn ==
    /\ turn = "stopped"
    /\ turn' = "committed"
    /\ UNCHANGED <<envVars, prompts, attempted, starts, title, catalog>>

(* A prompt queued behind the first turn starts as soon as it stops, which *)
(* can be before the stopped turn is committed.                            *)
SubmitSecondPrompt ==
    /\ prompts = 1
    /\ turn \in {"stopped", "committed"}
    /\ prompts' = 2
    /\ StartTitle(2)
    /\ UNCHANGED <<envVars, turn, catalog>>

TitleRead ==
    /\ title.phase = "reading"
    /\ title' = Read(title, TitleReadsStore)
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, catalog>>

TitleSend ==
    /\ title.phase = "sending"
    /\ title' = Send(title, TitleReplays(Len(title.sends) + 1))
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, catalog>>

TitleRecheck ==
    /\ title.phase = "checking"
    /\ RecheckStep(title)
    /\ title' = RecheckResult(title)
    /\ UNCHANGED <<memory, rotations, revocations, turn, prompts, attempted,
                   starts, catalog>>

(* A model list load starts (activity or the /model picker).              *)
CatalogStart ==
    /\ catalog.phase = "idle"
    /\ catalog' = [catalog EXCEPT !.phase = "reading"]
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, title>>

CatalogRead ==
    /\ catalog.phase = "reading"
    /\ catalog' = Read(catalog, CatalogReadsStore)
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, title>>

(* A model list that fails here falls back to the public list.            *)
CatalogSend ==
    /\ catalog.phase = "sending"
    /\ catalog' = Send(catalog, CatalogReplays(Len(catalog.sends) + 1))
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, title>>

CatalogRecheck ==
    /\ catalog.phase = "checking"
    /\ RecheckStep(catalog)
    /\ catalog' = RecheckResult(catalog)
    /\ UNCHANGED <<memory, rotations, revocations, turn, prompts, attempted,
                   starts, title>>

-----------------------------------------------------------------------------
(* The environment.                                                        *)

(* Another fx process refreshes the shared login.                          *)
OtherFxRefreshes ==
    /\ Refreshable
    /\ rotations < MaxRotations
    /\ rotations' = rotations + 1
    /\ store' = store + 1
    /\ \E keepOld \in BOOLEAN :
           accepted' = IF keepOld THEN accepted \cup {store + 1}
                       ELSE (accepted \cup {store + 1}) \ {store}
    /\ UNCHANGED <<storeTeam, memory, revocations, refreshes, turn, prompts,
                   attempted, starts, title, catalog>>

(* Another fx process signs in to another team. The gateway takes its      *)
(* token, for that team.                                                   *)
OtherFxSwitchesTeam ==
    /\ Refreshable
    /\ OtherTeam
    /\ storeTeam = "app"
    /\ store' = store + 1
    /\ storeTeam' = "other"
    /\ accepted' = accepted \cup {store + 1}
    /\ UNCHANGED <<memory, rotations, revocations, refreshes, turn, prompts,
                   attempted, starts, title, catalog>>

(* The gateway stops accepting the stored token before fx sees it expire.  *)
GatewayRevokesStored ==
    /\ revocations < MaxRevocations
    /\ store \in accepted
    /\ revocations' = revocations + 1
    /\ accepted' = accepted \ {store}
    /\ UNCHANGED <<store, storeTeam, memory, rotations, refreshes, turn,
                   prompts, attempted, starts, title, catalog>>

(* The main turn reads the store before its request and the app adopts a  *)
(* token of its own sign-in.                                               *)
WorkerAdopts ==
    /\ turn = "running"
    /\ storeTeam = "app"
    /\ memory # store
    /\ memory' = store
    /\ UNCHANGED <<store, storeTeam, accepted, rotations, revocations,
                   refreshes, turn, prompts, attempted, starts, title, catalog>>

-----------------------------------------------------------------------------
TitleStep == TitleRead \/ TitleSend \/ TitleRecheck
CatalogStep == CatalogRead \/ CatalogSend \/ CatalogRecheck

Environment ==
    \/ OtherFxRefreshes \/ OtherFxSwitchesTeam \/ GatewayRevokesStored
    \/ WorkerAdopts

Next ==
    \/ SubmitFirstPrompt \/ TurnStops \/ CommitTurn \/ SubmitSecondPrompt
    \/ TitleStep \/ CatalogStart \/ CatalogStep
    \/ Environment

Spec == Init /\ [][Next]_vars /\ WF_vars(TitleStep) /\ WF_vars(CatalogStep)

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

RequestOK(r) ==
    /\ r.phase \in Phases
    /\ r.prompt \in 0..2
    /\ r.team \in {"app", "other"}
    /\ r.readTeam \in {"app", "other"}
    /\ r.result \in {"none", "ok", "failed"}
    /\ r.noReplacement \in BOOLEAN

TypeOK ==
    /\ store \in Nat
    /\ storeTeam \in {"app", "other"}
    /\ memory \in 1..store
    /\ refreshes \in Nat
    /\ turn \in {"none", "running", "stopped", "committed"}
    /\ prompts \in 0..2
    /\ attempted \in BOOLEAN
    /\ RequestOK(title)
    /\ RequestOK(catalog)

(* Every session gets a title request on its first prompt.                 *)
FirstPromptStartsTitle == prompts >= 1 => starts >= 1

(* At most one title request per session.                                  *)
AtMostOneTitleRequest == starts <= 1

(* The title comes from the first prompt.                                  *)
TitleFromFirstPrompt == title.prompt \in {0, 1}

(* A request's first send carries the token the store held when it began,  *)
(* never a stale copy from memory, unless the store held another team's    *)
(* sign-in.                                                                *)
FirstSendUsesStore(r) ==
    Len(r.sends) >= 1 =>
        r.sends[1].tok = IF r.readTeam = "app" THEN r.read ELSE r.readMemory
TitleFirstSendUsesStore == FirstSendUsesStore(title)
CatalogFirstSendUsesStore == FirstSendUsesStore(catalog)

(* At most one more request after a rejection, and only after one.         *)
AtMostOneReplay(r) ==
    /\ Len(r.sends) <= 2
    /\ Len(r.sends) = 2 => ~r.sends[1].ok
TitleAtMostOneReplay == AtMostOneReplay(title)
CatalogAtMostOneReplay == AtMostOneReplay(catalog)

(* A static key is never sent twice.                                       *)
StaticKeyNeverReplays ==
    ~Refreshable => Len(title.sends) <= 1 /\ Len(catalog.sends) <= 1

(* A background request never refreshes the sign-in. Each refresh rotates  *)
(* the login all fx processes share, which can make the others stale.      *)
BackgroundNeverRefreshes == refreshes = 0

(* No request carries another team's sign-in.                              *)
SendsOnlyOwnTeam(r) == \A i \in 1..Len(r.sends) : r.sends[i].team = "app"
NeverSendsOtherTeam == SendsOnlyOwnTeam(title) /\ SendsOnlyOwnTeam(catalog)

(* A refreshable request gives up only after its one replay, or when the   *)
(* store held no other token of its sign-in.                               *)
GivesUpOnlyWhenUnrecoverable(r) ==
    r.result = "failed" => (~Refreshable \/ Len(r.sends) = 2 \/ r.noReplacement)
TitleGivesUpOnlyWhenUnrecoverable == GivesUpOnlyWhenUnrecoverable(title)
CatalogFallsBackOnlyWhenUnrecoverable == GivesUpOnlyWhenUnrecoverable(catalog)

(* Every request that starts finishes.                                     *)
TitleSettles == (title.phase # "idle") ~> (title.phase = "done")
CatalogSettles == (catalog.phase # "idle") ~> (catalog.phase = "done")

(* Bounds for TLC: the store's version cannot pass these.                  *)
StateBound == store <= 1 + MaxRotations + 3
=============================================================================
