------------------------------ MODULE CatalogOpen ------------------------------
(***************************************************************************)
(* The model catalog on the chat-open path: fx processes (ACP or fx ask)   *)
(* that start, read and write the one saved catalog file, crash at any     *)
(* step, and answer requests that read the catalog, while AI Gateway's     *)
(* catalog changes (src/core/gateway/saved_catalog.zig,                    *)
(* saved_catalog_plan.zig, and CapabilityResolver in gateway_provider.zig).*)
(*                                                                         *)
(* A process starts its catalog load at start (ACP `initialize`). In       *)
(* design "b" it first reads the saved file: one for its team that is not  *)
(* older than a day answers at once, and a young one needs no load. A      *)
(* load that fetches the team's catalog writes a temporary file and        *)
(* renames it over the saved one before it ends. A request takes a load    *)
(* that has ended, goes on with the catalog it holds while a load runs,    *)
(* and waits only when it holds none. Design "a" reads and writes no file. *)
(*                                                                         *)
(* Mutants (design "b"):                                                   *)
(*   "no-rename"          - the load writes the saved file in place.       *)
(*   "ignore-team"        - a start reads another team's file.             *)
(*   "use-old"            - a start uses a file older than a day.          *)
(*   "wait-with-catalog"  - a request with a catalog waits for a load.     *)
(*   "saved-marks-answer" - a saved catalog's Token Pass marks answer      *)
(*                          for the team.                                  *)
(*   "skip-landed"        - a request leaves a load that has ended.        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Procs, Teams, MaxVersion, Design, Mutant

Ages == {"young", "due", "old"}
NextAge == [young |-> "due", due |-> "old", old |-> "old"]
NoCatalog == [src |-> "none", team |-> "none", version |-> 0]
LoadStates == {"none", "running", "saving", "renaming", "landed", "failed"}

VARIABLES
    file,        \* the saved file: [present, whole, team, version, age]
    gw,          \* the catalog version AI Gateway serves now
    up,          \* [Procs -> BOOLEAN]: the process runs
    team,        \* [Procs -> Teams]: its credential's team
    cat,         \* [Procs -> [src, team, version]]: the catalog it holds
    load,        \* [Procs -> LoadStates]
    loadVer,     \* [Procs -> 0..MaxVersion]: what its load fetched
    waiting,     \* [Procs -> BOOLEAN]: a request waits for the load
    warm,        \* [Procs -> BOOLEAN]: it started with a usable saved file
    usedAge,     \* [Procs -> {"none"} \cup Ages]: the age of the file it used
    answer,      \* [Procs -> {"none", "fetched", "saved"}]: whose marks answered Token Pass
    stale        \* [Procs -> BOOLEAN]: a request after a load ended kept the older catalog

vars == <<file, gw, up, team, cat, load, loadVer, waiting, warm, usedAge, answer, stale>>

TypeOK ==
    /\ file \in [present : BOOLEAN, whole : BOOLEAN, team : Teams \cup {"none"},
                 version : 0..MaxVersion, age : Ages]
    /\ gw \in 1..MaxVersion
    /\ up \in [Procs -> BOOLEAN]
    /\ team \in [Procs -> Teams]
    /\ cat \in [Procs -> [src : {"none", "saved", "fetched"}, team : Teams \cup {"none"}, version : 0..MaxVersion]]
    /\ load \in [Procs -> LoadStates]
    /\ loadVer \in [Procs -> 0..MaxVersion]
    /\ waiting \in [Procs -> BOOLEAN]
    /\ warm \in [Procs -> BOOLEAN]
    /\ usedAge \in [Procs -> {"none"} \cup Ages]
    /\ answer \in [Procs -> {"none", "fetched", "saved"}]
    /\ stale \in [Procs -> BOOLEAN]

\* fx may find no saved file, or one an earlier run saved.
Init ==
    /\ file \in {[present |-> FALSE, whole |-> TRUE, team |-> "none", version |-> 0, age |-> "young"]}
              \cup [present : {TRUE}, whole : {TRUE}, team : Teams, version : {1}, age : Ages]
    /\ gw = 1
    /\ up = [p \in Procs |-> FALSE]
    /\ team \in [Procs -> Teams]
    /\ cat = [p \in Procs |-> NoCatalog]
    /\ load = [p \in Procs |-> "none"]
    /\ loadVer = [p \in Procs |-> 0]
    /\ waiting = [p \in Procs |-> FALSE]
    /\ warm = [p \in Procs |-> FALSE]
    /\ usedAge = [p \in Procs |-> "none"]
    /\ answer = [p \in Procs |-> "none"]
    /\ stale = [p \in Procs |-> FALSE]

\* saved_catalog.load and saved_catalog_plan.start: a whole file for the
\* team that is not older than a day.
GoodFile(t) == file.present /\ file.whole /\ file.team = t /\ file.age # "old"

Usable(t) ==
    /\ Design = "b"
    /\ file.present /\ file.whole
    /\ file.team = t \/ Mutant = "ignore-team"
    /\ file.age # "old" \/ Mutant = "use-old"

Start(p) ==
    /\ ~up[p]
    /\ \E t \in Teams :
        /\ team' = [team EXCEPT ![p] = t]
        /\ warm' = [warm EXCEPT ![p] = GoodFile(t)]
        /\ IF Usable(t)
           THEN /\ cat' = [cat EXCEPT ![p] = [src |-> "saved", team |-> file.team, version |-> file.version]]
                /\ usedAge' = [usedAge EXCEPT ![p] = file.age]
                \* A young saved catalog needs no load until it is due.
                /\ load' = [load EXCEPT ![p] = IF file.age = "young" THEN "none" ELSE "running"]
           ELSE /\ cat' = [cat EXCEPT ![p] = NoCatalog]
                /\ usedAge' = [usedAge EXCEPT ![p] = "none"]
                /\ load' = [load EXCEPT ![p] = "running"]
    /\ up' = [up EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<file, gw, loadVer, waiting, answer, stale>>

\* The load's request answers with what AI Gateway serves now.
Fetched(p) ==
    /\ up[p] /\ load[p] = "running"
    /\ loadVer' = [loadVer EXCEPT ![p] = gw]
    /\ load' = [load EXCEPT ![p] = IF Design = "b" THEN "saving" ELSE "landed"]
    /\ UNCHANGED <<file, gw, up, team, cat, waiting, warm, usedAge, answer, stale>>

FetchFailed(p) ==
    /\ up[p] /\ load[p] = "running"
    /\ load' = [load EXCEPT ![p] = "failed"]
    /\ UNCHANGED <<file, gw, up, team, cat, loadVer, waiting, warm, usedAge, answer, stale>>

\* durableReplaceVerified writes a temporary file of its own first.
WriteTemp(p) ==
    /\ up[p] /\ load[p] = "saving"
    /\ IF Mutant = "no-rename"
       THEN file' = [file EXCEPT !.present = TRUE, !.whole = FALSE]
       ELSE UNCHANGED file
    /\ load' = [load EXCEPT ![p] = "renaming"]
    /\ UNCHANGED <<gw, up, team, cat, loadVer, waiting, warm, usedAge, answer, stale>>

\* The rename replaces the file whole, and the load ends after it.
Rename(p) ==
    /\ up[p] /\ load[p] = "renaming"
    /\ file' = [present |-> TRUE, whole |-> TRUE, team |-> team[p], version |-> loadVer[p], age |-> "young"]
    /\ load' = [load EXCEPT ![p] = "landed"]
    /\ UNCHANGED <<gw, up, team, cat, loadVer, waiting, warm, usedAge, answer, stale>>

\* saved_catalog_plan.request for a request that reads the catalog:
\* session/new, session/load, set_config_option, or a prompt's start.
Request(p) ==
    /\ up[p] /\ ~waiting[p]
    /\ IF load[p] = "landed" /\ Mutant # "skip-landed"
       THEN /\ cat' = [cat EXCEPT ![p] = [src |-> "fetched", team |-> team[p], version |-> loadVer[p]]]
            /\ load' = [load EXCEPT ![p] = "none"]
            /\ UNCHANGED waiting
       ELSE IF load[p] = "failed"
       THEN \* A failed load leaves the catalog fx holds; with none, the request answers from fallbacks.
            /\ load' = [load EXCEPT ![p] = "none"]
            /\ UNCHANGED <<cat, waiting>>
       ELSE IF cat[p].src # "none"
       THEN IF Mutant = "wait-with-catalog" /\ load[p] \in {"running", "saving", "renaming"}
            THEN /\ waiting' = [waiting EXCEPT ![p] = TRUE]
                 /\ UNCHANGED <<cat, load>>
            ELSE \* Go on; a due catalog starts a load in the background.
                 /\ \/ load[p] = "none" /\ load' = [load EXCEPT ![p] = "running"]
                    \/ UNCHANGED load
                 /\ UNCHANGED <<cat, waiting>>
       ELSE \* No catalog: wait for a load, starting one if none runs.
            /\ waiting' = [waiting EXCEPT ![p] = TRUE]
            /\ load' = [load EXCEPT ![p] = IF load[p] = "none" THEN "running" ELSE load[p]]
            /\ UNCHANGED cat
    /\ stale' = [stale EXCEPT ![p] = stale[p] \/ (load[p] = "landed" /\ cat'[p].version < loadVer[p])]
    /\ UNCHANGED <<file, gw, up, team, loadVer, warm, usedAge, answer>>

\* A waiting request ends when the load ends, either way.
Served(p) ==
    /\ up[p] /\ waiting[p] /\ load[p] \in {"landed", "failed"}
    /\ cat' = [cat EXCEPT ![p] = IF load[p] = "landed"
                                 THEN [src |-> "fetched", team |-> team[p], version |-> loadVer[p]]
                                 ELSE cat[p]]
    /\ load' = [load EXCEPT ![p] = "none"]
    /\ waiting' = [waiting EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<file, gw, up, team, loadVer, warm, usedAge, answer, stale>>

\* token_pass_team.catalogAnswers: only a fetched catalog's marks answer.
MarksAnswer(p) ==
    /\ up[p] /\ answer[p] = "none" /\ cat[p].src # "none"
    /\ cat[p].src = "fetched" \/ Mutant = "saved-marks-answer"
    /\ answer' = [answer EXCEPT ![p] = cat[p].src]
    /\ UNCHANGED <<file, gw, up, team, cat, load, loadVer, waiting, warm, usedAge, stale>>

\* kill -9 at any step: the saved file stays as it is, and a temporary file
\* written before the rename is left beside it.
Crash(p) ==
    /\ up[p]
    /\ up' = [up EXCEPT ![p] = FALSE]
    /\ cat' = [cat EXCEPT ![p] = NoCatalog]
    /\ load' = [load EXCEPT ![p] = "none"]
    /\ loadVer' = [loadVer EXCEPT ![p] = 0]
    /\ waiting' = [waiting EXCEPT ![p] = FALSE]
    /\ warm' = [warm EXCEPT ![p] = FALSE]
    /\ usedAge' = [usedAge EXCEPT ![p] = "none"]
    /\ answer' = [answer EXCEPT ![p] = "none"]
    /\ stale' = [stale EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<file, gw, team>>

Age ==
    /\ file.present /\ file.age # "old"
    /\ file' = [file EXCEPT !.age = NextAge[file.age]]
    /\ UNCHANGED <<gw, up, team, cat, load, loadVer, waiting, warm, usedAge, answer, stale>>

CatalogChanges ==
    /\ gw < MaxVersion
    /\ gw' = gw + 1
    /\ UNCHANGED <<file, up, team, cat, load, loadVer, waiting, warm, usedAge, answer, stale>>

Next ==
    \/ \E p \in Procs :
        \/ Start(p) \/ Fetched(p) \/ FetchFailed(p) \/ WriteTemp(p) \/ Rename(p)
        \/ Request(p) \/ Served(p) \/ MarksAnswer(p) \/ Crash(p)
    \/ Age
    \/ CatalogChanges

Spec == Init /\ [][Next]_vars

\* The load runs to its end; a crash may come first.
FairSpec ==
    /\ Spec
    /\ \A p \in Procs : WF_vars(Fetched(p) \/ FetchFailed(p)) /\ WF_vars(WriteTemp(p)) /\ WF_vars(Rename(p)) /\ WF_vars(Served(p))

-----------------------------------------------------------------------------
\* A reader always finds the saved file whole: a crash leaves the old file
\* or the new one (RULES.md R3.4).
FileWhole == file.present => file.whole

\* No process uses another team's catalog.
OwnTeamOnly == \A p \in Procs : cat[p].src # "none" => cat[p].team = team[p]

\* A saved catalog older than a day never answers.
NeverOlderThanADay == \A p \in Procs : usedAge[p] # "old"

\* Once a process holds a catalog for its team, no request waits for the
\* network.
NeverWaitWithCatalog == \A p \in Procs : waiting[p] => cat[p].src = "none"

\* A start with a usable saved file never waits (what design "a" lacks).
WarmStartNeverWaits == \A p \in Procs : waiting[p] => ~warm[p]

\* A saved catalog's Token Pass marks never answer for the team.
SavedMarksNeverAnswer == \A p \in Procs : answer[p] # "saved"

\* The first request after a load ends takes its catalog.
LandedTakenNext == \A p \in Procs : ~stale[p]

\* A waiting request ends.
WaitEnds == \A p \in Procs : waiting[p] ~> ~waiting[p]
=============================================================================
