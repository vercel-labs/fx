---------------------------- MODULE SnapshotTail ----------------------------
(***************************************************************************)
(* Step: load() returns a snapshot plus the events after it              *)
(* (the store's `snapshot?(bytes, at)` handoff).                         *)
(*                                                                         *)
(* The session state is a fold of the journal. The backend may store a   *)
(* snapshot (the fold of a prefix) to shorten loads. Restoring from any  *)
(* stored snapshot plus the tail after it must equal replaying the whole *)
(* durable journal. A snapshot may only cover durable events: events     *)
(* that were only sent can vanish in a crash.                            *)
(*                                                                         *)
(* The fold is order-sensitive (count plus last value) so that a skipped *)
(* or reordered event changes the result.                                *)
(*                                                                         *)
(* A store keeps one snapshot and drops the events it covers. Any valid  *)
(* snapshot can reach it at any time: `snapshot()` is not an append, so  *)
(* one taken by an agent that another has since replaced can arrive      *)
(* late. The store keeps a snapshot only if it is newer than its own.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxLen

VARIABLES
    log,     \* the session's events: durable prefix plus a pending tail
    dlen,    \* how many events are durable
    snaps,   \* every snapshot taken: [at, state]
    latest,  \* the one snapshot a trimming store keeps
    trimmed  \* how many leading events that store has dropped

vars == <<log, dlen, snaps, latest, trimmed>>

Empty == [n |-> 0, last |-> 0]

StepState(st, v) == [n |-> st.n + 1, last |-> v]

RECURSIVE FoldFrom(_, _, _)
FoldFrom(st, s, i) ==
    IF i > Len(s) THEN st ELSE FoldFrom(StepState(st, s[i]), s, i + 1)

Fold(s) == FoldFrom(Empty, s, 1)

\* How the kernel restores: the snapshot's state, then the events after it.
RestoreFrom(snap) == FoldFrom(snap.state, log, snap.at + 1)

State == [n : 0..MaxLen, last : Vals \cup {0}]

TypeOK ==
    /\ log \in Seq(Vals)
    /\ Len(log) <= MaxLen
    /\ dlen \in 0..Len(log)
    /\ snaps \subseteq [at : 0..MaxLen, state : State]
    /\ latest \in [at : 0..MaxLen, state : State]
    /\ trimmed \in 0..MaxLen

Init ==
    /\ log = <<>>
    /\ dlen = 0
    /\ snaps = {}
    /\ latest = [at |-> 0, state |-> Empty]
    /\ trimmed = 0

\* The kernel emits an event (sent, not yet durable).
Emit(v) ==
    /\ Len(log) < MaxLen
    /\ log' = Append(log, v)
    /\ UNCHANGED <<dlen, snaps, latest, trimmed>>

\* The next event becomes durable.
Persist ==
    /\ dlen < Len(log)
    /\ dlen' = dlen + 1
    /\ UNCHANGED <<log, snaps, latest, trimmed>>

\* The backend stores a snapshot of a durable prefix.
Snapshot ==
    /\ \E at \in 0..dlen :
        snaps' = snaps \cup {[at |-> at, state |-> Fold(SubSeq(log, 1, at))]}
    /\ UNCHANGED <<log, dlen, latest, trimmed>>

\* A snapshot reaches the trimming store, perhaps late: the store keeps it
\* only if it is newer than its own, then drops the events it covers.
Offer ==
    /\ \E s \in snaps :
        IF s.at > latest.at
        THEN /\ latest' = s
             /\ trimmed' = s.at
        ELSE UNCHANGED <<latest, trimmed>>
    /\ UNCHANGED <<log, dlen, snaps>>

\* The process dies; events that were not durable are gone.
Crash ==
    /\ dlen < Len(log)
    /\ log' = SubSeq(log, 1, dlen)
    /\ UNCHANGED <<dlen, snaps, latest, trimmed>>

Next ==
    \/ \E v \in Vals : Emit(v)
    \/ Persist
    \/ Snapshot
    \/ Offer
    \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A snapshot never covers an event the log does not have.
SnapshotNotAhead == \A s \in snaps : s.at <= Len(log)

\* Restoring from any stored snapshot equals replaying the whole log.
ResumeEqualsFullReplay == \A s \in snaps : RestoreFrom(s) = Fold(log)

\* Every stored snapshot is exactly the fold of the prefix it claims to
\* cover, so dropping snapshots (replaying from event 1) loses nothing.
SnapshotMatchesPrefix ==
    \A s \in snaps : s.at <= Len(log) /\ s.state = Fold(SubSeq(log, 1, s.at))

\* The trimming store's snapshot covers exactly the events it dropped.
SnapshotsMoveForward == latest.at = trimmed

\* What the trimming store loads (its snapshot, then the events it kept)
\* equals replaying the whole log.
LoadEqualsFullReplay == FoldFrom(latest.state, log, trimmed + 1) = Fold(log)

=============================================================================
