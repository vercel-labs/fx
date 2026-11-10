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
(* The design: a request reads the store before its first send; after a   *)
(* 401 it reads the store again and sends with a newer token if there is   *)
(* one, and forces a refresh only when the store still holds the rejected  *)
(* token; it sends at most once more; a static key never refreshes. The    *)
(* session records that a title request started, and the gate checks that *)
(* record.                                                                 *)
(*                                                                         *)
(* Tokens are versions: the store holds one, the gateway accepts a set,    *)
(* and the app's memory holds one. Other fx processes refresh the login    *)
(* (a new version, the old one kept or revoked), the gateway may stop      *)
(* accepting the stored token, the issuer may fail, the main turn may      *)
(* adopt the stored token into memory.                                     *)
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
    Bug

Bugs == {"none", "today", "no-reload", "no-replay", "double-replay",
         "force-no-recheck", "replay-static-key", "history-gate",
         "catalog-no-reload", "catalog-no-replay"}

ASSUME /\ Refreshable \in BOOLEAN
       /\ MaxRotations \in Nat
       /\ MaxRevocations \in Nat
       /\ Bug \in Bugs

VARIABLES
    store,        \* version of the token in the credential store
    accepted,     \* versions the gateway accepts
    memory,       \* version the app holds in memory
    rotations,    \* refreshes other fx processes made
    revocations,  \* stored tokens the gateway stopped accepting
    issuer,       \* "up": a forced refresh succeeds; "down": it fails
    turn,         \* the first turn: "none", "running", "stopped", "committed"
    prompts,      \* prompts submitted
    attempted,    \* the session's record that a title request started
    starts,       \* title requests started
    title,        \* the title request
    catalog       \* the model list load

vars == <<store, accepted, memory, rotations, revocations, issuer, turn,
          prompts, attempted, starts, title, catalog>>

envVars == <<store, accepted, memory, rotations, revocations, issuer>>

(* One background request. sends is every request it made to the gateway,  *)
(* in order, with the token it carried and whether the gateway took it.    *)
(* read is the store's version when the request began. heldRejected is     *)
(* whether the store still held the rejected token when the request read   *)
(* it again after a 401.                                                   *)
Idle == [phase |-> "idle", prompt |-> 0, tok |-> 0, read |-> 0,
         rejected |-> 0, sends |-> <<>>, heldRejected |-> FALSE,
         forced |-> FALSE, forceFailed |-> FALSE, result |-> "none"]

Phases == {"idle", "reading", "sending", "checking", "forcing", "done"}

-----------------------------------------------------------------------------
(* What each variant does.                                                 *)

TitleReadsStore == Bug \notin {"today", "no-reload"}
CatalogReadsStore == Bug \notin {"today", "catalog-no-reload"}
Rechecks == Bug # "force-no-recheck"
GateUsesRecord == Bug \notin {"today", "history-gate"}

(* Whether a request that has made n requests and was just rejected sends  *)
(* again.                                                                  *)
TitleReplays(n) ==
    CASE Bug \in {"today", "no-replay"} -> FALSE
      [] Bug = "double-replay" -> Refreshable /\ n <= 2
      [] Bug = "replay-static-key" -> n = 1
      [] OTHER -> Refreshable /\ n = 1

CatalogReplays(n) ==
    CASE Bug \in {"today", "catalog-no-replay"} -> FALSE
      [] OTHER -> Refreshable /\ n = 1

-----------------------------------------------------------------------------
(* Steps of one request, shared by the title and the model list.           *)

Read(r, fromStore) ==
    [r EXCEPT !.phase = "sending",
              !.tok = IF fromStore THEN store ELSE memory,
              !.read = store]

Send(r, replays) ==
    LET ok == r.tok \in accepted
        log == Append(r.sends, [tok |-> r.tok, ok |-> ok])
    IN  IF ok
        THEN [r EXCEPT !.phase = "done", !.sends = log, !.result = "ok"]
        ELSE IF replays
             THEN [r EXCEPT !.phase = "checking", !.sends = log, !.rejected = r.tok]
             ELSE [r EXCEPT !.phase = "done", !.sends = log, !.result = "failed"]

(* After a 401: a newer stored token is sent at once; otherwise refresh.   *)
Recheck(r) ==
    LET held == store = r.rejected
    IN  IF Rechecks /\ ~held
        THEN [r EXCEPT !.phase = "sending", !.tok = store, !.heldRejected = FALSE]
        ELSE [r EXCEPT !.phase = "forcing", !.heldRejected = held]

-----------------------------------------------------------------------------
Init ==
    /\ store = 1
    /\ accepted = {1}
    /\ memory = 1
    /\ rotations = 0
    /\ revocations = 0
    /\ issuer = "up"
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
    /\ title' = Recheck(title)
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, catalog>>

(* A forced refresh issues a new version; the issuer may revoke the old.   *)
TitleForce ==
    /\ title.phase = "forcing"
    /\ IF issuer = "up"
       THEN /\ store' = store + 1
            /\ \E keepOld \in BOOLEAN :
                   accepted' = IF keepOld THEN accepted \cup {store + 1}
                               ELSE (accepted \cup {store + 1}) \ {store}
            /\ title' = [title EXCEPT !.phase = "sending", !.tok = store + 1, !.forced = TRUE]
       ELSE /\ title' = [title EXCEPT !.phase = "done", !.result = "failed", !.forceFailed = TRUE]
            /\ UNCHANGED <<store, accepted>>
    /\ UNCHANGED <<memory, rotations, revocations, issuer, turn, prompts,
                   attempted, starts, catalog>>

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
    /\ catalog' = Recheck(catalog)
    /\ UNCHANGED <<envVars, turn, prompts, attempted, starts, title>>

CatalogForce ==
    /\ catalog.phase = "forcing"
    /\ IF issuer = "up"
       THEN /\ store' = store + 1
            /\ \E keepOld \in BOOLEAN :
                   accepted' = IF keepOld THEN accepted \cup {store + 1}
                               ELSE (accepted \cup {store + 1}) \ {store}
            /\ catalog' = [catalog EXCEPT !.phase = "sending", !.tok = store + 1, !.forced = TRUE]
       ELSE /\ catalog' = [catalog EXCEPT !.phase = "done", !.result = "failed", !.forceFailed = TRUE]
            /\ UNCHANGED <<store, accepted>>
    /\ UNCHANGED <<memory, rotations, revocations, issuer, turn, prompts,
                   attempted, starts, title>>

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
    /\ UNCHANGED <<memory, revocations, issuer, turn, prompts, attempted,
                   starts, title, catalog>>

(* The gateway stops accepting the stored token before fx sees it expire.  *)
GatewayRevokesStored ==
    /\ revocations < MaxRevocations
    /\ store \in accepted
    /\ revocations' = revocations + 1
    /\ accepted' = accepted \ {store}
    /\ UNCHANGED <<store, memory, rotations, issuer, turn, prompts,
                   attempted, starts, title, catalog>>

IssuerFails ==
    /\ Refreshable
    /\ issuer = "up"
    /\ issuer' = "down"
    /\ UNCHANGED <<store, accepted, memory, rotations, revocations, turn,
                   prompts, attempted, starts, title, catalog>>

(* The main turn reads the store before its request and the app adopts it. *)
WorkerAdopts ==
    /\ turn = "running"
    /\ memory # store
    /\ memory' = store
    /\ UNCHANGED <<store, accepted, rotations, revocations, issuer, turn,
                   prompts, attempted, starts, title, catalog>>

-----------------------------------------------------------------------------
TitleStep == TitleRead \/ TitleSend \/ TitleRecheck \/ TitleForce
CatalogStep == CatalogRead \/ CatalogSend \/ CatalogRecheck \/ CatalogForce

Environment ==
    \/ OtherFxRefreshes \/ GatewayRevokesStored \/ IssuerFails
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
    /\ r.result \in {"none", "ok", "failed"}
    /\ r.forced \in BOOLEAN
    /\ r.forceFailed \in BOOLEAN
    /\ r.heldRejected \in BOOLEAN

TypeOK ==
    /\ store \in Nat
    /\ memory \in 1..store
    /\ turn \in {"none", "running", "stopped", "committed"}
    /\ prompts \in 0..2
    /\ attempted \in BOOLEAN
    /\ issuer \in {"up", "down"}
    /\ RequestOK(title)
    /\ RequestOK(catalog)

(* Every session gets a title request on its first prompt.                 *)
FirstPromptStartsTitle == prompts >= 1 => starts >= 1

(* At most one title request per session.                                  *)
AtMostOneTitleRequest == starts <= 1

(* The title comes from the first prompt.                                  *)
TitleFromFirstPrompt == title.prompt \in {0, 1}

(* A request's first send carries the token the store held when it began,  *)
(* never a stale copy from memory.                                         *)
FirstSendUsesStore(r) ==
    Len(r.sends) >= 1 => r.sends[1].tok = r.read
TitleFirstSendUsesStore == FirstSendUsesStore(title)
CatalogFirstSendUsesStore == FirstSendUsesStore(catalog)

(* At most one more request after a rejection, and only after one.         *)
AtMostOneReplay(r) ==
    /\ Len(r.sends) <= 2
    /\ Len(r.sends) = 2 => ~r.sends[1].ok
TitleAtMostOneReplay == AtMostOneReplay(title)
CatalogAtMostOneReplay == AtMostOneReplay(catalog)

(* A static key is never refreshed and never sent twice.                   *)
StaticKeyNeverReplays ==
    ~Refreshable =>
        /\ Len(title.sends) <= 1 /\ ~title.forced
        /\ Len(catalog.sends) <= 1 /\ ~catalog.forced

(* A forced refresh happens only when the store still held the rejected    *)
(* token. Each forced refresh rotates the shared login, which can make     *)
(* other fx processes stale.                                               *)
NoNeedlessRefresh ==
    /\ title.forced => title.heldRejected
    /\ catalog.forced => catalog.heldRejected

(* A refreshable request gives up only after its one replay, or when the   *)
(* refresh itself failed.                                                  *)
GivesUpOnlyWhenUnrecoverable(r) ==
    r.result = "failed" => (~Refreshable \/ Len(r.sends) = 2 \/ r.forceFailed)
TitleGivesUpOnlyWhenUnrecoverable == GivesUpOnlyWhenUnrecoverable(title)
CatalogFallsBackOnlyWhenUnrecoverable == GivesUpOnlyWhenUnrecoverable(catalog)

(* Every request that starts finishes.                                     *)
TitleSettles == (title.phase # "idle") ~> (title.phase = "done")
CatalogSettles == (catalog.phase # "idle") ~> (catalog.phase = "done")

(* Bounds for TLC: the store's version cannot pass these.                  *)
StateBound == store <= 1 + MaxRotations + 2
=============================================================================
