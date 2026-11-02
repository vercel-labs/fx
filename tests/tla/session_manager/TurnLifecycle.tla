--------------------------- MODULE TurnLifecycle ---------------------------
(***************************************************************************)
(* Step: L2 turn rules, close, crash and reopen repair.                   *)
(*                                                                         *)
(* A host may ask for any kind in any order. The manager appends only     *)
(* valid transitions and rejects the rest (InvalidTransition). close()   *)
(* interrupts an open turn before `closed`. open(.resume) interrupts a    *)
(* turn left open by a crash. Byte-level durability is SessionLog.tla's   *)
(* job; here a crash keeps the log exactly as written. Every interrupt    *)
(* reason (host: cancel, failed; manager: closed, crash) is one           *)
(* "interrupt": the turn rules do not depend on it (D21).                 *)
(*                                                                         *)
(* Design: system-design.md kinds table and "Fold".                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANT MaxLen

HostKinds == {"start", "item", "compacted", "commit", "interrupt", "set"}
Kinds == HostKinds \cup {"created", "closed"}

VARIABLES
    log,     \* the session log as a sequence of kinds
    status,  \* "new", "open", "closed" or "down"
    fresh    \* TRUE right after open(.resume), until the next turn starts

vars == <<log, status, fresh>>

Count(l, k) == Cardinality({i \in 1..Len(l) : l[i] = k})
Ends(l) == Count(l, "commit") + Count(l, "interrupt")
IsOpen(l) == Count(l, "start") > Ends(l)

Prefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a

\* What the manager accepts from a host.
Valid(l, k) ==
    CASE k = "start"     -> ~IsOpen(l)
      [] k = "item"      -> IsOpen(l)
      [] k = "commit"    -> IsOpen(l)
      [] k = "interrupt" -> IsOpen(l)
      [] k = "compacted" -> TRUE
      [] k = "set"       -> TRUE

TypeOK ==
    /\ log \in Seq(Kinds)
    /\ status \in {"new", "open", "closed", "down"}
    /\ fresh \in BOOLEAN

Init ==
    /\ log = <<>>
    /\ status = "new"
    /\ fresh = FALSE

\* The first turn publishes the session with line 1 (D2).
Create ==
    /\ status = "new"
    /\ log' = <<"created">>
    /\ status' = "open"
    /\ UNCHANGED fresh

\* A host asks to append k; only valid kinds are written.
Write(k) ==
    /\ status = "open"
    /\ Len(log) < MaxLen
    /\ Valid(log, k)
    /\ log' = Append(log, k)
    /\ fresh' = (fresh /\ k # "start")
    /\ UNCHANGED status

\* close(): an open turn is interrupted, then `closed` is appended.
Close ==
    /\ status = "open"
    /\ Len(log) + 2 <= MaxLen
    /\ log' = IF IsOpen(log)
                 THEN log \o <<"interrupt", "closed">>
                 ELSE Append(log, "closed")
    /\ status' = "closed"
    /\ fresh' = FALSE

\* fx dies with the session open.
Crash ==
    /\ status = "open"
    /\ status' = "down"
    /\ UNCHANGED <<log, fresh>>

\* open(.resume): a turn left open by a crash gets turn_interrupted.
Reopen ==
    /\ status \in {"closed", "down"}
    /\ Len(log) < MaxLen
    /\ log' = IF IsOpen(log) THEN Append(log, "interrupt") ELSE log
    /\ status' = "open"
    /\ fresh' = TRUE

Next ==
    \/ Create
    \/ \E k \in HostKinds : Write(k)
    \/ Close
    \/ Crash
    \/ Reopen

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

StartsWithCreated == Len(log) > 0 => log[1] = "created"

AtMostOneOpenTurn == Count(log, "start") - Ends(log) \in {0, 1}

ItemsInsideTurns ==
    \A i \in 1..Len(log) :
        log[i] = "item" => IsOpen(SubSeq(log, 1, i - 1))

EndsCloseATurn ==
    \A i \in 1..Len(log) :
        log[i] \in {"commit", "interrupt"} => IsOpen(SubSeq(log, 1, i - 1))

ClosedOnlyBetweenTurns ==
    \A i \in 1..Len(log) :
        log[i] = "closed" => ~IsOpen(SubSeq(log, 1, i - 1))

\* After open(.resume), no turn from the previous owner is still open.
NoStaleTurnAfterReopen == fresh => ~IsOpen(log)

(* Action property: the log is only ever extended, never rewritten. *)
AppendOnly == [][Prefix(log, log')]_vars
=============================================================================
