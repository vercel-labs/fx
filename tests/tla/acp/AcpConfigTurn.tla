--------------------------- MODULE AcpConfigTurn ---------------------------
(***************************************************************************)
(* session/set_config_option while a turn runs in fx acp. A settings       *)
(* version stands for the model, provider, credential, Fast, Ultrafast     *)
(* and effort that the session held after a change.                        *)
(*                                                                         *)
(*  - A change is answered at once, also while a turn runs.                *)
(*  - The running turn keeps its own copy of the settings it started       *)
(*    with, and every model request of the turn uses that copy.            *)
(*  - The next turn starts with the settings the last change left.         *)
(*  - A change frees the session's old settings, and the running turn      *)
(*    never reads memory a change freed.                                   *)
(*  - A credential the running turn renews goes to the session only while  *)
(*    the session still has the turn's provider.                           *)
(*                                                                         *)
(* Rules = FALSE gives fx acp before these rules: a change during a turn   *)
(* fails with -32600 "Prompt already in progress", and the turn borrows    *)
(* the session's settings.                                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Rules,       \* TRUE: these rules; FALSE: fx acp before them
    Providers,
    MaxTurns,
    MaxRequests, \* model requests per turn
    MaxChanges

P0 == CHOOSE p \in Providers : TRUE

VARIABLES
    version,   \* the session's settings version; 0 is the first
    provOf,    \* provOf[v]: the provider that settings version v names
    credProv,  \* the provider the session's credential belongs to
    freed,     \* the settings versions whose memory a change freed
    running,   \* whether a turn runs
    turnVer,   \* the settings version the running turn uses
    owned,     \* TRUE: the turn owns a copy; FALSE: it borrows the session's
    startVer,  \* the session's version when the running turn started
    turns, reqs, changes,
    log,       \* each model request: its turn, version, start version, and
               \* whether it read freed memory
    answers    \* each set_config_option answer: "ok" or "busy"
vars == <<version, provOf, credProv, freed, running, turnVer, owned, startVer,
          turns, reqs, changes, log, answers>>

Init ==
    /\ version = 0
    /\ provOf = [v \in 0..MaxChanges |-> P0]
    /\ credProv = P0
    /\ freed = {}
    /\ running = FALSE
    /\ turnVer = 0
    /\ owned = Rules
    /\ startVer = 0
    /\ turns = 0 /\ reqs = 0 /\ changes = 0
    /\ log = <<>>
    /\ answers = <<>>

\* A prompt starts a turn. Under the rules the turn copies the session's
\* settings; before them it borrows the session's memory.
StartTurn ==
    /\ ~running /\ turns < MaxTurns
    /\ running' = TRUE
    /\ turns' = turns + 1
    /\ reqs' = 0
    /\ turnVer' = version
    /\ startVer' = version
    /\ owned' = Rules
    /\ UNCHANGED <<version, provOf, credProv, freed, changes, log, answers>>

\* The running turn makes a model request with the settings it holds.
Request ==
    /\ running /\ reqs < MaxRequests
    /\ log' = Append(log, [turn |-> turns, ver |-> turnVer, start |-> startVer,
                           readFreed |-> ~owned /\ turnVer \in freed])
    /\ reqs' = reqs + 1
    /\ UNCHANGED <<version, provOf, credProv, freed, running, turnVer, owned,
                   startVer, turns, changes, answers>>

\* session/set_config_option picks settings that name provider p, with a
\* credential for p, and frees the session's old settings.
SetConfig(p) ==
    /\ changes < MaxChanges
    /\ changes' = changes + 1
    /\ IF ~Rules /\ running
       THEN /\ answers' = Append(answers, "busy")
            /\ UNCHANGED <<version, provOf, credProv, freed>>
       ELSE /\ answers' = Append(answers, "ok")
            /\ version' = version + 1
            /\ provOf' = [provOf EXCEPT ![version + 1] = p]
            /\ freed' = freed \cup {version}
            /\ credProv' = p
    /\ UNCHANGED <<running, turnVer, owned, startVer, turns, reqs, log>>

\* The running turn renews its credential and offers it to the session, which
\* takes it only while it still has the turn's provider.
Renew ==
    /\ running
    /\ credProv' = IF ~Rules \/ provOf[version] = provOf[turnVer]
                   THEN provOf[turnVer] ELSE credProv
    /\ UNCHANGED <<version, provOf, freed, running, turnVer, owned, startVer,
                   turns, reqs, changes, log, answers>>

EndTurn ==
    /\ running
    /\ running' = FALSE
    /\ UNCHANGED <<version, provOf, credProv, freed, turnVer, owned, startVer,
                   turns, reqs, changes, log, answers>>

Next ==
    \/ StartTurn \/ Request \/ Renew \/ EndTurn
    \/ \E p \in Providers : SetConfig(p)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ version \in 0..MaxChanges
    /\ running \in BOOLEAN /\ owned \in BOOLEAN
    /\ credProv \in Providers
    /\ freed \subseteq 0..MaxChanges

\* A change is answered at once, also during a turn.
AnswersDuringTurn == \A k \in DOMAIN answers : answers[k] = "ok"

\* Every model request of one turn uses the same settings.
TurnKeepsItsSettings ==
    \A i, j \in DOMAIN log : log[i].turn = log[j].turn => log[i].ver = log[j].ver

\* A turn uses the settings the session held when it started.
NextTurnUsesLatest == \A k \in DOMAIN log : log[k].ver = log[k].start

\* No model request reads settings memory that a change freed.
NoFreedRead == \A k \in DOMAIN log : ~log[k].readFreed

\* The session's credential belongs to the provider its settings name.
CredentialMatchesProvider == credProv = provOf[version]
=============================================================================
