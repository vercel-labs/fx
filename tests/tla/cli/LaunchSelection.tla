---------------------------- MODULE LaunchSelection ----------------------------
(***************************************************************************)
(* Launch-time model, speed and effort flags for `fx` and `fx ask`.        *)
(*                                                                         *)
(* One scenario fixes what the user asked for, what the catalog load       *)
(* returns, and what the chosen model supports. The machine then runs the  *)
(* entry point:                                                            *)
(*                                                                         *)
(*   ask:          AskValidate -> Send                                     *)
(*   interactive:  FirstFrame, then CatalogReady and Submit in the order   *)
(*                 the scenario fixes (early = submit before the catalog). *)
(*                                                                         *)
(* Send applies the turn-time gates that exist in both designs: Fast is    *)
(* masked unless the catalog confirms it, Ultra fails the turn unless the  *)
(* catalog confirms it, and effort is dropped unless the catalog lists it. *)
(*                                                                         *)
(* Design = "current" has no launch validation at all. Design =          *)
(* "proposed" validates at launch. Mutant plants one bug in the proposed  *)
(* design so each invariant is shown to fail when its rule is broken.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
  Design,   \* "current" | "proposed"
  Mutant,   \* "none" | "reject_weak" | "no_canonical" | "block_frame" | "persist" | "silent"
  Class     \* "all" | "ideal" | "nonideal": which scenarios Init may pick

ASSUME Design \in {"current", "proposed"}
ASSUME Mutant \in {"none", "reject_weak", "no_canonical", "block_frame", "persist", "silent"}
ASSUME Class \in {"all", "ideal", "nonideal"}

VARIABLE st
vars == <<st>>

(* ----------------------------- Scenarios -------------------------------- *)

Paths      == {"ask", "interactive"}
(* none: no --model flag, the configured model is used.                     *)
(* private_hidden: a real team model that only an authenticated catalog     *)
(* lists; the anonymous public catalog does not.                            *)
ModelReqs  == {"none", "exact", "partial_unique", "partial_ambiguous", "unknown", "private_hidden"}
SpeedReqs  == {"none", "fast", "ultrafast", "off"}
EffortReqs == {"none", "supported", "unsupported"}
(* absent: a provider without a catalog, such as a configured provider.     *)
Catalogs   == {"authenticated", "anonymous", "failed", "absent"}

ScenarioSpace ==
  [path: Paths, model: ModelReqs, speed: SpeedReqs, effort: EffortReqs,
   catalog: Catalogs, fastCap: BOOLEAN, ultraCap: BOOLEAN, early: BOOLEAN]

Ideal(s) ==
  /\ s.catalog = "authenticated"
  /\ s.model \in {"none", "exact"}
  /\ s.speed = "fast" => s.fastCap
  /\ s.speed = "ultrafast" => s.ultraCap
  /\ s.effort # "unsupported"
  /\ ~s.early

Scenarios ==
  { s \in ScenarioSpace :
      /\ s.path = "ask" => ~s.early
      /\ CASE Class = "all"      -> TRUE
           [] Class = "ideal"    -> Ideal(s)
           [] Class = "nonideal" -> ~Ideal(s) }

(* ------------------------- Catalog and gateway --------------------------- *)

Loaded(s)        == s.catalog \in {"authenticated", "anonymous"}
Authoritative(s) == s.catalog = "authenticated"

(* What matchCatalogModel returns for the --model text.                     *)
Match(s) ==
  IF ~Loaded(s) THEN "no_catalog"
  ELSE CASE s.model = "none"              -> "none"
         [] s.model = "exact"             -> "matched"
         [] s.model = "partial_unique"    -> "matched"
         [] s.model = "partial_ambiguous" -> "ambiguous"
         [] s.model = "unknown"           -> "unknown"
         [] s.model = "private_hidden"    -> IF Authoritative(s) THEN "matched" ELSE "unknown"

(* Model names: "raw" is the --model text, "canonical" the catalog ID,      *)
(* "configured" the saved model. An exact ID is already canonical.          *)
Name(s, m) == IF m = "raw" /\ s.model \in {"exact", "private_hidden"} THEN "canonical" ELSE m

(* The real gateway accepts a name only when that model exists.             *)
GatewayAccepts(s, m) == Name(s, m) \in {"canonical", "configured"}

(* fx knows the capabilities of the model it will send only when the loaded *)
(* catalog lists that exact name.                                           *)
CapKnownFor(s, m) ==
  /\ Loaded(s)
  /\ \/ Name(s, m) = "configured"
     \/ /\ Name(s, m) = "canonical"
        /\ (s.model = "private_hidden" => Authoritative(s))

(* -------------------------------- State ---------------------------------- *)

(* Placeholder before any request; after = FALSE keeps it out of every check. *)
NoReq ==
  [ model |-> "none", claimedFast |-> FALSE, wireFast |-> FALSE, claimedUltra |-> FALSE,
    wireUltra |-> FALSE, claimedEffort |-> "none", wireEffort |-> "none", after |-> FALSE ]

Fresh(s) ==
  [ sc          |-> s,
    phase       |-> "start",          \* start | running | done
    catalogSeen |-> FALSE,            \* interactive: the UI saw the load finish
    sel         |-> [ model  |-> IF s.model = "none" THEN "configured" ELSE "raw",
                      fast   |-> s.speed = "fast",
                      ultra  |-> s.speed = "ultrafast",
                      effort |-> s.effort ],
    outcome     |-> "pending",
    req         |-> NoReq,
    corrections |-> {},
    notices     |-> {},
    persisted   |-> FALSE ]

Init == st \in { Fresh(s) : s \in Scenarios }

S == st.sc

(* The proposed decision, shared by both entry points.                      *)
ModelRejected(s) ==
  /\ Match(s) \in {"ambiguous", "unknown"}
  /\ (Authoritative(s) \/ Mutant = "reject_weak")

Resolved(s, cur) ==
  IF Match(s) = "matched" /\ Mutant # "no_canonical" THEN "canonical" ELSE cur

(* -------------------------------- ask ------------------------------------ *)

AskValidate ==
  /\ S.path = "ask"
  /\ st.phase = "start"
  /\ IF Design = "current"
       THEN st' = [st EXCEPT !.phase = "running"]
       ELSE LET m == Resolved(S, st.sel.model)
                k == CapKnownFor(S, m)
                reason ==
                  CASE ModelRejected(S)                                  -> "rejected_model"
                    [] st.sel.ultra /\ ~(k /\ S.ultraCap)                -> "rejected_ultrafast"
                    [] st.sel.fast /\ k /\ ~S.fastCap                    -> "rejected_fast"
                    [] st.sel.effort = "unsupported" /\ k                -> "rejected_effort"
                    [] OTHER                                             -> "none"
            IN st' = [st EXCEPT !.sel.model = m,
                                !.phase = IF reason = "none" THEN "running" ELSE "done",
                                !.outcome = IF reason = "none" THEN "pending" ELSE reason]

(* ----------------------------- interactive ------------------------------- *)

FirstFrame ==
  /\ S.path = "interactive"
  /\ st.phase = "start"
  /\ Mutant = "block_frame" => st.catalogSeen
  /\ st' = [st EXCEPT !.phase = "running"]

Corrected(s, sel) ==
  IF ModelRejected(s)
    THEN [ sel |-> [model |-> "configured", fast |-> FALSE, ultra |-> FALSE, effort |-> "none"],
           corrections |-> {"model"} ]
    ELSE LET m == Resolved(s, sel.model)
             k == CapKnownFor(s, m)
             fast   == sel.fast /\ ~(k /\ ~s.fastCap)
             ultra  == sel.ultra /\ k /\ s.ultraCap
             effort == IF sel.effort = "unsupported" /\ k THEN "none" ELSE sel.effort
         IN [ sel |-> [model |-> m, fast |-> fast, ultra |-> ultra, effort |-> effort],
              corrections |-> { c \in {"fast", "ultrafast", "effort"} :
                                  CASE c = "fast"      -> fast # sel.fast
                                    [] c = "ultrafast" -> ultra # sel.ultra
                                    [] c = "effort"    -> effort # sel.effort } ]

CatalogReady ==
  /\ S.path = "interactive"
  /\ ~st.catalogSeen
  /\ S.early => st.phase = "done"
  /\ IF Design = "current"
       THEN st' = [st EXCEPT !.catalogSeen = TRUE]
       ELSE LET c == Corrected(S, st.sel) IN
            st' = [st EXCEPT !.catalogSeen = TRUE,
                             !.sel = c.sel,
                             !.corrections = c.corrections,
                             !.notices = IF Mutant = "silent" THEN {} ELSE c.corrections,
                             !.persisted = Mutant = "persist" /\ c.corrections # {}]

(* ------------------------------- sending --------------------------------- *)

Send ==
  /\ st.phase = "running"
  /\ S.path = "interactive" => (S.early <=> ~st.catalogSeen)
  /\ LET m == st.sel.model
         k == CapKnownFor(S, m)
     IN IF st.sel.ultra /\ ~(k /\ S.ultraCap)
          THEN st' = [st EXCEPT !.phase = "done", !.outcome = "turn_error"]
          ELSE st' = [st EXCEPT
                 !.phase = "done",
                 !.outcome = IF GatewayAccepts(S, m) THEN "sent" ELSE "gateway_error",
                 !.req = [ model        |-> Name(S, m),
                           claimedFast  |-> st.sel.fast,
                           wireFast     |-> st.sel.fast /\ k /\ S.fastCap,
                           claimedUltra |-> st.sel.ultra,
                           wireUltra    |-> st.sel.ultra,
                           claimedEffort |-> st.sel.effort,
                           wireEffort   |-> IF st.sel.effort = "supported" /\ k THEN "supported" ELSE "none",
                           after        |-> S.path = "ask" \/ st.catalogSeen ]]

Finished ==
  /\ st.phase = "done"
  /\ S.path = "interactive" => st.catalogSeen

Next ==
  \/ AskValidate
  \/ FirstFrame
  \/ CatalogReady
  \/ Send
  \/ (Finished /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* Weak fairness: an enabled step eventually happens, so every run ends.    *)
FairSpec == Spec /\ WF_vars(Next)

(* ------------------------------ Invariants ------------------------------- *)

(* A request sent after the decision point (always for ask; after the UI    *)
(* saw the catalog for interactive).                                        *)
Decided == st.req.after

(* With an authenticated catalog, fx never sends a model that does not exist. *)
ValidModel == Decided /\ Authoritative(S) => GatewayAccepts(S, st.req.model)

(* When fx knows the capabilities, the speed it shows is the speed it sends. *)
HonestSpeed ==
  Decided /\ CapKnownFor(S, st.req.model) =>
    /\ st.req.claimedFast = st.req.wireFast
    /\ st.req.claimedUltra = st.req.wireUltra

(* When fx knows the capabilities, the effort it claims is the effort it sends. *)
HonestEffort ==
  Decided /\ CapKnownFor(S, st.req.model) => st.req.claimedEffort = st.req.wireEffort

(* fx ask fails during validation, never with a late turn error.            *)
AskFailsEarly == S.path = "ask" => st.outcome # "turn_error"

(* Every rejection or correction is backed by catalog evidence.             *)
NoFalseReject ==
  /\ (st.outcome = "rejected_model" \/ "model" \in st.corrections) =>
       Authoritative(S) /\ S.model \in {"partial_ambiguous", "unknown"}
  /\ (st.outcome = "rejected_fast" \/ "fast" \in st.corrections) =>
       CapKnownFor(S, st.sel.model) /\ ~S.fastCap
  /\ (st.outcome = "rejected_effort" \/ "effort" \in st.corrections) =>
       CapKnownFor(S, st.sel.model) /\ S.effort = "unsupported"
  /\ (st.outcome = "rejected_ultrafast" \/ "ultrafast" \in st.corrections) =>
       ~(CapKnownFor(S, st.sel.model) /\ S.ultraCap)

(* A unique partial name runs on its catalog ID.                            *)
Canonical == Decided /\ S.model = "partial_unique" /\ Loaded(S) => st.req.model = "canonical"

(* Per-launch flags never rewrite saved settings.                           *)
SettingsUntouched == ~st.persisted

(* The interactive first frame never waits for the catalog.                 *)
FirstFrameNotBlocked == (S.path = "interactive" /\ st.phase = "start") => ENABLED FirstFrame

(* Every automatic correction is announced.                                 *)
CorrectionsAnnounced == st.corrections \subseteq st.notices

(* Every behavior ends.                                                     *)
Termination == <>Finished
=============================================================================
