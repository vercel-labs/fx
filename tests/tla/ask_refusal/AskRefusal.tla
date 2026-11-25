---------------------------- MODULE AskRefusal ----------------------------
(***************************************************************************)
(* One tool call that fx refuses, as `fx ask` shows it on stderr and       *)
(* records it in --json. Two calls run side by side.                       *)
(*                                                                         *)
(* A call takes one path. A call that a hook or a bad argument blocks goes *)
(* straight to refusal, without a review. A shell call starts its visible  *)
(* lifecycle first. A configured deny or a missing terminal refuses it at  *)
(* once. A call that the rules leave to the auto reviewer starts a review, *)
(* and the review either holds the call (stage "held") or admits it. A     *)
(* held call is refused, or admitted when a fresh review clears it. A file *)
(* call waits for its permission check and refuses there. Cancel can stop  *)
(* a call before it closes, when Class allows cancel.                      *)
(*                                                                         *)
(* Design "today" is origin/main. The visible start, and its "Running"     *)
(* line on stderr, come before the review, or at the refusal for a call    *)
(* that starts late. A refusal prints nothing on stderr and records no     *)
(* reason. A reviewed call prints nothing for the review.                  *)
(* Design "a" keeps the visible start for the TUI and ACP. It prints       *)
(* "Running" on stderr only when a call is admitted, prints the refusal    *)
(* once with its reason, and records the reason in the JSON entry. A       *)
(* reviewed call prints "Reviewing" once, when its review starts, before   *)
(* its "Running" or "Refused" line. A call that is not reviewed prints no  *)
(* "Reviewing" line.                                                       *)
(* Design "b" starts a call's visible row only when it is admitted. During *)
(* a review the row shows "Reviewing". Its stderr is the same as "a".      *)
(* Mutant plants one bug in one design, so each invariant is shown to      *)
(* fail when its rule is broken.                                           *)
(*                                                                         *)
(* Invariants: NoRunningForRefused, RefusalTold, JsonReason,               *)
(* NothingChangesForRun, ReviewTold, ReviewShowsRow. Termination needs     *)
(* FairSpec.                                                               *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS
  Design,  \* "today" | "a" | "b"
  Mutant,  \* "none", or one planted bug in one design
  Class    \* "all" | "ideal" | "nonideal": "ideal" has no cancel

ASSUME Design \in {"today", "a", "b"}
ASSUME Mutant \in {"none", "a_early_print", "a_no_reason", "a_twice",
                   "a_cancel_print", "a_run_reason", "a_no_reviewing",
                   "a_settle_reviewing", "b_early_start", "b_no_review_row"}
ASSUME Class \in {"all", "ideal", "nonideal"}

Calls  == {"c1", "c2"}
Kinds  == {"run", "hook", "validation", "deny", "caution", "unavail", "noterm", "file"}
Stages == {"idle", "reviewing", "held", "admitted", "refusing", "cancelled", "closed"}

(* An early kind starts its visible lifecycle before its review, as shell   *)
(* does on main. A late kind starts only when it refuses: a hook or a bad   *)
(* argument blocks it before any review, and a file target starts after its *)
(* permission check.                                                        *)
EarlyKinds == {"run", "deny", "caution", "unavail", "noterm"}
LateKinds  == {"hook", "validation", "file"}
(* A review that holds the call names one of these. A missing terminal is  *)
(* a refusal with no review, so it is not here.                            *)
HeldKinds  == {"caution", "unavail"}
(* A call of one of these kinds never reaches the auto reviewer. A "run"    *)
(* call may or may not reach it: the rules can allow it with no review.     *)
NoReviewKinds == {"hook", "validation", "deny", "noterm", "file"}

Reason(k) ==
  CASE k = "hook"       -> "R_HOOK"
    [] k = "validation" -> "R_ARGS"
    [] k = "deny"       -> "R_DENY"
    [] k = "caution"    -> "R_CAUTION"
    [] k = "unavail"    -> "R_UNAVAILABLE"
    [] k = "noterm"     -> "R_NO_TERMINAL"
    [] k = "file"       -> "R_FILE"
    [] OTHER            -> ""

VARIABLES kind, reviewed, stage, admitted, reviewStarted, printedRun, pendingRun,
          rowOn, held, printedReviewing, printedRefusal, shownReason, recReason, outcome

vars == <<kind, reviewed, stage, admitted, reviewStarted, printedRun, pendingRun,
          rowOn, held, printedReviewing, printedRefusal, shownReason, recReason, outcome>>

IsLate(c) == kind[c] \in LateKinds

EarlyPrint    == Design = "today" \/ (Design = "a" /\ Mutant = "a_early_print")
                 \/ (Design = "b" /\ Mutant = "b_early_start")
NoReviewRow   == Design = "b" /\ Mutant = "b_no_review_row"
(* "Reviewing" prints when the review starts. The planted bug prints it at  *)
(* the settle instead, after the review has already answered.               *)
PrintAtStart  == (Design = "a" /\ Mutant \notin {"a_no_reviewing", "a_settle_reviewing"})
                 \/ Design = "b"
PrintAtSettle == Design = "a" /\ Mutant = "a_settle_reviewing"
CancelAllowed == Class # "ideal"

RecordedReason(c) ==
  IF stage[c] = "refusing" /\ Design # "today" /\ Mutant # "a_no_reason"
    THEN Reason(kind[c])
  ELSE IF stage[c] = "admitted" /\ Design = "a" /\ Mutant = "a_run_reason"
    THEN "R_RUN"
  ELSE ""

(* ------------------------------- Init ----------------------------------- *)

Init ==
  /\ kind \in [Calls -> Kinds]
  /\ reviewed \in [Calls -> BOOLEAN]
  /\ \A c \in Calls: kind[c] \in HeldKinds => reviewed[c]
  /\ \A c \in Calls: kind[c] \in NoReviewKinds => ~reviewed[c]
  /\ stage = [c \in Calls |-> "idle"]
  /\ admitted = [c \in Calls |-> FALSE]
  /\ reviewStarted = [c \in Calls |-> FALSE]
  /\ printedRun = [c \in Calls |-> FALSE]
  /\ pendingRun = [c \in Calls |-> FALSE]
  /\ rowOn = [c \in Calls |-> FALSE]
  /\ held = [c \in Calls |-> FALSE]
  /\ printedReviewing = [c \in Calls |-> 0]
  /\ printedRefusal = [c \in Calls |-> 0]
  /\ shownReason = [c \in Calls |-> ""]
  /\ recReason = [c \in Calls |-> ""]
  /\ outcome = [c \in Calls |-> "none"]

(* ------------------------------ Actions --------------------------------- *)

(* An early kind starts its visible lifecycle before the review. *)
Begin(c) ==
  /\ stage[c] = "idle"
  /\ kind[c] \in EarlyKinds
  /\ stage' = [stage EXCEPT ![c] = "reviewing"]
  /\ printedRun' = IF EarlyPrint THEN [printedRun EXCEPT ![c] = TRUE] ELSE printedRun
  /\ pendingRun' = IF EarlyPrint THEN pendingRun ELSE [pendingRun EXCEPT ![c] = TRUE]
  /\ rowOn' = IF NoReviewRow THEN rowOn ELSE [rowOn EXCEPT ![c] = TRUE]
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, held, printedReviewing,
                 printedRefusal, shownReason, recReason, outcome>>

(* A file target waits for its permission check. Design "b" shows a row    *)
(* for that wait; the other designs show none, as on main.                 *)
Review(c) ==
  /\ stage[c] = "idle"
  /\ kind[c] = "file"
  /\ stage' = [stage EXCEPT ![c] = "reviewing"]
  /\ rowOn' = IF Design = "b" THEN [rowOn EXCEPT ![c] = TRUE] ELSE rowOn
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, printedRun, pendingRun,
                 held, printedReviewing, printedRefusal, shownReason, recReason, outcome>>

(* An auto review starts for a call. fx ask prints "Reviewing" once, here,  *)
(* before the review answers and before any "Running" or "Refused" line.    *)
StartReview(c) ==
  /\ stage[c] = "reviewing"
  /\ reviewed[c]
  /\ ~reviewStarted[c]
  /\ reviewStarted' = [reviewStarted EXCEPT ![c] = TRUE]
  /\ printedReviewing' = IF PrintAtStart THEN [printedReviewing EXCEPT ![c] = 1]
                         ELSE printedReviewing
  /\ UNCHANGED <<kind, reviewed, stage, admitted, printedRun, pendingRun, rowOn, held,
                 printedRefusal, shownReason, recReason, outcome>>

(* The review holds the call. It starts only after its review started.      *)
Hold(c) ==
  /\ stage[c] = "reviewing"
  /\ kind[c] \in HeldKinds
  /\ reviewStarted[c]
  /\ stage' = [stage EXCEPT ![c] = "held"]
  /\ held' = [held EXCEPT ![c] = TRUE]
  /\ printedReviewing' = IF PrintAtSettle THEN [printedReviewing EXCEPT ![c] = 1]
                         ELSE printedReviewing
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, printedRun, pendingRun,
                 rowOn, printedRefusal, shownReason, recReason, outcome>>

(* The refusal. A late kind starts its visible row here, as on main.       *)
(* Designs "a" and "b" print the refusal once with its reason and drop the  *)
(* pending "Running" line, which was never printed. Design "b" starts no    *)
(* row for a late kind. A missing terminal ("noterm") is refused here too:  *)
(* its refusal message is the blocker notice, which names the reason, so no *)
(* "Refused" line follows it.                                              *)
Refuse(c) ==
  /\ \/ (stage[c] = "idle" /\ kind[c] \in {"hook", "validation"})
     \/ (stage[c] = "reviewing" /\ kind[c] \in {"deny", "noterm", "file"})
     \/ (stage[c] = "held" /\ kind[c] \in HeldKinds)
  /\ stage' = [stage EXCEPT ![c] = "refusing"]
  /\ printedRun' = IF Design = "today" /\ IsLate(c)
                     THEN [printedRun EXCEPT ![c] = TRUE]
                     ELSE printedRun
  /\ rowOn' = IF IsLate(c) /\ Design # "b"
                THEN [rowOn EXCEPT ![c] = TRUE]
                ELSE rowOn
  /\ printedRefusal' = IF Design = "today" THEN printedRefusal
                       ELSE [printedRefusal EXCEPT ![c] =
                               IF Design = "a" /\ Mutant = "a_twice" THEN 2 ELSE 1]
  /\ shownReason' = IF Design = "today" THEN shownReason
                    ELSE [shownReason EXCEPT ![c] = Reason(kind[c])]
  /\ pendingRun' = IF Design = "today" THEN pendingRun
                   ELSE [pendingRun EXCEPT ![c] = FALSE]
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, held, printedReviewing,
                 recReason, outcome>>

(* An admitted run prints its "Running" line now, in designs "a" and "b".   *)
(* A run admitted by review, or a caution that a fresh review clears. A      *)
(* reviewed run is admitted only after its review started. An unavailable   *)
(* review is never cleared by a second review, so only a caution is admitted *)
(* from a hold.                                                             *)
Admit(c) ==
  /\ \/ (stage[c] = "reviewing" /\ kind[c] = "run" /\ (~reviewed[c] \/ reviewStarted[c]))
     \/ (stage[c] = "held" /\ kind[c] = "caution")
  /\ stage' = [stage EXCEPT ![c] = "admitted"]
  /\ admitted' = [admitted EXCEPT ![c] = TRUE]
  /\ printedRun' = IF Design = "today" THEN printedRun
                   ELSE [printedRun EXCEPT ![c] = TRUE]
  /\ pendingRun' = IF Design = "today" THEN pendingRun
                   ELSE [pendingRun EXCEPT ![c] = FALSE]
  /\ printedReviewing' = IF PrintAtSettle /\ reviewed[c]
                           THEN [printedReviewing EXCEPT ![c] = 1]
                           ELSE printedReviewing
  /\ UNCHANGED <<kind, reviewed, reviewStarted, rowOn, held, printedRefusal,
                 shownReason, recReason, outcome>>

(* Cancel stops a call that has not closed. Design "a" with the planted     *)
(* bug prints the pending "Running" line on the way out.                    *)
Cancel(c) ==
  /\ CancelAllowed
  /\ stage[c] \in {"idle", "reviewing", "held", "admitted"}
  /\ stage' = [stage EXCEPT ![c] = "cancelled"]
  /\ printedRun' = IF Design = "a" /\ Mutant = "a_cancel_print" /\ pendingRun[c]
                     THEN [printedRun EXCEPT ![c] = TRUE]
                     ELSE printedRun
  /\ pendingRun' = [pendingRun EXCEPT ![c] = FALSE]
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, rowOn, held, printedReviewing,
                 printedRefusal, shownReason, recReason, outcome>>

Close(c) ==
  /\ stage[c] \in {"refusing", "admitted", "cancelled"}
  /\ stage' = [stage EXCEPT ![c] = "closed"]
  /\ outcome' = [outcome EXCEPT ![c] =
                   IF stage[c] = "refusing" THEN "refused"
                   ELSE IF stage[c] = "admitted" THEN "ran"
                   ELSE "cancelled"]
  /\ recReason' = [recReason EXCEPT ![c] = RecordedReason(c)]
  /\ UNCHANGED <<kind, reviewed, admitted, reviewStarted, printedRun, pendingRun, rowOn,
                 held, printedReviewing, printedRefusal, shownReason>>

Done == (\A c \in Calls: stage[c] = "closed") /\ UNCHANGED vars

Next == \E c \in Calls:
          Begin(c) \/ Review(c) \/ StartReview(c) \/ Hold(c) \/ Refuse(c)
          \/ Admit(c) \/ Cancel(c) \/ Close(c)
        \/ Done

Spec == Init /\ [][Next]_vars

Progress(c) == Begin(c) \/ Review(c) \/ StartReview(c) \/ Hold(c) \/ Refuse(c)
               \/ Admit(c) \/ Close(c)
FairSpec == Spec /\ \A c \in Calls: WF_vars(Progress(c))

(* ----------------------------- Invariants ------------------------------- *)

TypeOK ==
  /\ kind \in [Calls -> Kinds]
  /\ reviewed \in [Calls -> BOOLEAN]
  /\ stage \in [Calls -> Stages]
  /\ admitted \in [Calls -> BOOLEAN]
  /\ reviewStarted \in [Calls -> BOOLEAN]
  /\ printedRun \in [Calls -> BOOLEAN]
  /\ pendingRun \in [Calls -> BOOLEAN]
  /\ rowOn \in [Calls -> BOOLEAN]
  /\ held \in [Calls -> BOOLEAN]
  /\ printedReviewing \in [Calls -> 0..2]
  /\ printedRefusal \in [Calls -> 0..2]
  /\ shownReason \in [Calls -> STRING]
  /\ recReason \in [Calls -> STRING]
  /\ outcome \in [Calls -> {"none", "refused", "ran", "cancelled"}]

(* fx ask prints "Running" for a call only after admission let it run. *)
NoRunningForRefused == \A c \in Calls: printedRun[c] => admitted[c]

(* A refused call shows its refusal message once on stderr, with its reason: *)
(* a "Refused" line, or for a missing terminal the blocker notice.            *)
RefusalTold ==
  \A c \in Calls:
    /\ printedRefusal[c] <= 1
    /\ ((outcome[c] = "refused") =>
          (printedRefusal[c] = 1 /\ shownReason[c] = Reason(kind[c])))

(* The --json entry of a refused call carries its reason. *)
JsonReason == \A c \in Calls: outcome[c] = "refused" => recReason[c] = Reason(kind[c])

(* A call that is not reviewed and runs prints the lines it prints today: a *)
(* "Running" line, no refusal, no reason, and no "Reviewing" line.          *)
NothingChangesForRun ==
  \A c \in Calls:
    (outcome[c] = "ran" /\ ~reviewed[c]) =>
      (printedRun[c] /\ printedRefusal[c] = 0 /\ recReason[c] = ""
        /\ printedReviewing[c] = 0)

(* A reviewed call prints "Reviewing" once, when its review starts, before  *)
(* any "Running" or "Refused" line. A call that is not reviewed prints none. *)
(* A reviewed call that the turn cancels before admission prints no final   *)
(* line and no "Running" line; a call admitted before the cancel keeps the  *)
(* "Running" line it printed.                                               *)
ReviewTold ==
  \A c \in Calls:
    /\ printedReviewing[c] <= 1
    /\ (~reviewed[c] => printedReviewing[c] = 0)
    /\ (reviewStarted[c] => reviewed[c])
    /\ (reviewStarted[c] => printedReviewing[c] = 1)
    /\ ((reviewed[c] /\ (printedRun[c] \/ printedRefusal[c] > 0)) => reviewStarted[c])
    /\ (reviewed[c] /\ outcome[c] = "cancelled" /\ ~admitted[c]) =>
         (~printedRun[c] /\ printedRefusal[c] = 0)

(* A shell call under review keeps the working row it shows on main (R2.1). *)
ReviewShowsRow ==
  \A c \in Calls:
    (stage[c] \in {"reviewing", "held"} /\ kind[c] \in EarlyKinds) => rowOn[c]

Termination == <>(\A c \in Calls: stage[c] = "closed")

=============================================================================
