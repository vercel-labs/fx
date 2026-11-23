------------------------------- MODULE Prune -------------------------------
(***************************************************************************)
(* The one-time cleanup of an old session's log.                           *)
(*                                                                         *)
(* A legacy log holds superseded legacy usage lines, the old per-reply      *)
(* totals that carried a whole usage state, and superseded snapshots. The  *)
(* cleanup replaces each of them with a `pruned` line that keeps its seq,  *)
(* so every reader's seq check still passes and every seq a fork or a      *)
(* child names still means the same line. Per-reply usage lines are never  *)
(* replaced: a fork point reads their totals. It recomputes each kept      *)
(* snapshot's usage value (the meaning of the lines it covers) and its     *)
(* compaction offset, a byte offset that moves when a line before it       *)
(* shrinks. The original log is hard-linked before the rename, under the   *)
(* writer lock, so a crash at any step leaves a whole log and the original.*)
(*                                                                         *)
(* Design = "today" has no cleanup, so its legacy log keeps dead weight.   *)
(* Each mutant plants one bug in the cleanup.                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Design,   \* "today" | "prune"
  Mutant,   \* "none" | "drop_renumber" | "drop_gap" | "stale_off" | "newest_usage" | "new_shape" | "relink" | "no_lock" | "delete_orig" | "drop_newest_snap" | "drop_tail"
  MaxLines, \* bound on lines in the log
  MaxVal    \* bound on usage totals

ASSUME Design \in {"today", "prune"}
ASSUME Mutant \in {"none", "drop_renumber", "drop_gap", "stale_off", "newest_usage",
                   "new_shape", "relink", "no_lock", "delete_orig", "drop_newest_snap", "drop_tail"}

\* Bytes per line kind, a model of the line sizes that move offsets.
Bytes(k) == CASE k = "created" -> 4
                 [] k = "legacy" -> 10
                 [] k = "usage" -> 10
                 [] k = "snapshot" -> 8
                 [] k = "compacted" -> 5
                 [] k = "pruned" -> 2
                 [] OTHER -> 3

Rec(s, k, v, c, o) == [seq |-> s, kind |-> k, val |-> v, cov |-> c, off |-> o]

Idx(l, k) == {i \in 1..Len(l) : l[i].kind = k}
Max(S) == CHOOSE i \in S : \A j \in S : j <= i

\* Usage lines: the legacy totals, and the per-reply totals.
UsageKinds == {"legacy", "usage"}
UIdx(l) == {i \in 1..Len(l) : l[i].kind \in UsageKinds}

\* The totals a reader folds: the newest usage line's value. A legacy value
\* reads as no totals, so it counts as zero.
Meaning(l) ==
  LET u == UIdx(l)
  IN IF u = {} THEN 0
     ELSE IF l[Max(u)].kind = "legacy" THEN 0 ELSE l[Max(u)].val

RECURSIVE PosRec(_, _)
PosRec(l, i) == IF i <= 1 THEN 0 ELSE Bytes(l[i - 1].kind) + PosRec(l, i - 1)

\* The byte offset of the last compacted line within lines 1..n, or 0.
CompOffAt(l, n) ==
  LET c == {i \in 1..n : l[i].kind = "compacted"}
  IN IF c = {} THEN 0 ELSE PosRec(l, Max(c))

\* Lines a cleanup may replace: a legacy usage line with a newer usage line
\* after it, and every snapshot but the newest.
Prunable(l) ==
  LET u == UIdx(l)
      s == Idx(l, "snapshot")
      older == IF u = {} THEN {} ELSE u \ {Max(u)}
  IN  (IF Mutant = "newest_usage" THEN u
       ELSE IF Mutant = "new_shape" THEN older
       ELSE {i \in older : l[i].kind = "legacy"})
      \cup (IF s = {} THEN {} ELSE IF Mutant = "drop_newest_snap" THEN s ELSE s \ {Max(s)})

Place(l, P) ==
  [i \in 1..Len(l) |-> IF i \in P THEN Rec(l[i].seq, "pruned", 0, 0, 0) ELSE l[i]]

Drop(l, P) ==
  LET doomed == {l[j].seq : j \in P}
      kept == SelectSeq(l, LAMBDA r : ~(r.seq \in doomed))
  IN IF Mutant = "drop_renumber"
       THEN [i \in 1..Len(kept) |-> [kept[i] EXCEPT !.seq = i]]
       ELSE kept

\* A kept snapshot takes the meaning and the offset that the rewrite computes
\* for the lines it covers. The stale_off mutant keeps the old offset.
Stamp(l) ==
  [i \in 1..Len(l) |->
     IF l[i].kind = "snapshot" /\ l[i].cov <= Len(l)
       THEN [l[i] EXCEPT !.val = Meaning(SubSeq(l, 1, l[i].cov)),
                         !.off = IF Mutant = "stale_off" THEN l[i].off
                                 ELSE CompOffAt(l, l[i].cov)]
       ELSE l[i]]

NewLog(l, P) ==
  IF Mutant \in {"drop_renumber", "drop_gap"} THEN Drop(l, P) ELSE Stamp(Place(l, P))

\* The legacy log the cleanup starts from. Its offsets are the real ones.
LegacyKinds == <<"created", "legacy", "legacy", "item", "snapshot", "legacy",
                 "compacted", "legacy", "snapshot", "legacy">>
LKs == [i \in 1..Len(LegacyKinds) |-> [kind |-> LegacyKinds[i]]]
Legacy ==
  [i \in 1..Len(LegacyKinds) |->
     Rec(i, LegacyKinds[i], 0,
         IF LegacyKinds[i] = "snapshot" THEN i - 1 ELSE 0,
         IF LegacyKinds[i] = "snapshot" THEN CompOffAt(LKs, i - 1) ELSE 0)]

VARIABLES log, orig, origKept, pruned, phase, tmp, open

vars == <<log, orig, origKept, pruned, phase, tmp, open>>

Init ==
  /\ log = Legacy
  /\ orig = <<>>
  /\ origKept = FALSE
  /\ pruned = FALSE
  /\ phase = "idle"
  /\ tmp = <<>>
  /\ open = FALSE

\* The writer appends only while no cleanup holds the lock.
AppendUsage ==
  /\ ~open /\ Len(log) < MaxLines /\ Meaning(log) < MaxVal
  /\ log' = log \o <<Rec(Len(log) + 1, "usage", Meaning(log) + 1, 0, 0)>>
  /\ UNCHANGED <<orig, origKept, pruned, phase, tmp, open>>

AppendItem ==
  /\ ~open /\ Len(log) < MaxLines
  /\ log' = log \o <<Rec(Len(log) + 1, "item", 0, 0, 0)>>
  /\ UNCHANGED <<orig, origKept, pruned, phase, tmp, open>>

AppendCompacted ==
  /\ ~open /\ Len(log) < MaxLines
  /\ log' = log \o <<Rec(Len(log) + 1, "compacted", 0, 0, 0)>>
  /\ UNCHANGED <<orig, origKept, pruned, phase, tmp, open>>

AppendSnapshot ==
  /\ ~open /\ Len(log) < MaxLines
  /\ log' = log \o <<Rec(Len(log) + 1, "snapshot", Meaning(log), Len(log), CompOffAt(log, Len(log)))>>
  /\ UNCHANGED <<orig, origKept, pruned, phase, tmp, open>>

PruneStart ==
  /\ Design = "prune" /\ phase = "idle"
  /\ Mutant = "no_lock" \/ ~open
  /\ Prunable(log) # {}
  /\ open' = (Mutant # "no_lock")
  /\ orig' = IF origKept /\ Mutant # "relink" THEN orig ELSE log
  /\ origKept' = TRUE
  /\ phase' = "linked"
  /\ UNCHANGED <<log, pruned, tmp>>

PruneWrite ==
  /\ phase = "linked"
  /\ tmp' = NewLog(log, Prunable(log))
  /\ phase' = "written"
  /\ UNCHANGED <<log, orig, origKept, pruned, open>>

PruneRename ==
  /\ phase = "written"
  /\ log' = tmp
  /\ pruned' = TRUE
  /\ phase' = "idle"
  /\ open' = FALSE
  /\ tmp' = <<>>
  /\ origKept' = IF Mutant = "delete_orig" THEN FALSE ELSE origKept
  /\ UNCHANGED orig

\* A crash drops the lock and the unfinished tmp. The hard link survives.
Crash ==
  /\ phase' = "idle"
  /\ open' = FALSE
  /\ tmp' = <<>>
  /\ UNCHANGED <<log, orig, origKept, pruned>>

PruneActions == PruneStart \/ PruneWrite \/ PruneRename

\* The restored log: the first original, then every line of the current log past
\* it. A placeholder past the original stood for a snapshot that a repeat cleanup
\* superseded, so it is written again. Every snapshot takes the meaning and the
\* offset of where it now sits.
RestoredLog(o, l) ==
  LET n == Len(o)
      tail == [i \in 1..(Len(l) - n) |->
                 IF l[n + i].kind = "pruned"
                   THEN Rec(l[n + i].seq, "snapshot", 0, l[n + i].seq - 1, 0)
                   ELSE l[n + i]]
      joined == [i \in 1..Len(l) |-> IF i <= n THEN o[i] ELSE tail[i - n]]
  IN Stamp(joined)

\* Restore keeps the tail. It runs under the writer lock, and the kept original
\* goes away after the rename, so the log is the restored one from then on.
Restore ==
  /\ Design = "prune" /\ pruned /\ origKept /\ phase = "idle" /\ ~open
  /\ log' = IF Mutant = "drop_tail" THEN orig ELSE RestoredLog(orig, log)
  /\ pruned' = FALSE
  /\ origKept' = FALSE
  /\ orig' = <<>>
  /\ UNCHANGED <<phase, tmp, open>>

NextSafe ==
  \/ AppendUsage \/ AppendItem \/ AppendCompacted \/ AppendSnapshot
  \/ PruneActions
  \/ Restore
  \/ Crash

NextLive == PruneActions

SpecSafe == Init /\ [][NextSafe]_vars
SpecLive == Init /\ [][NextLive]_vars /\ WF_vars(PruneStart) /\ WF_vars(PruneWrite) /\ WF_vars(PruneRename)

\* The log is numbered 1..n, and no line was removed without a stand-in.
SeqContiguous == \A i \in 1..Len(log) : log[i].seq = i

\* A cleanup holds the writer lock from its first step to its rename.
Lock == phase # "idle" => open

\* Every line the cleanup kept still has its own seq, kind and value.
SeqPreserved ==
  pruned => \A i \in 1..Len(log) :
    (log[i].kind # "pruned" /\ log[i].seq <= Len(orig)) =>
      (orig[log[i].seq].kind = log[i].kind /\ orig[log[i].seq].val = log[i].val)

\* A reader that starts at any line of the original sees the same totals and
\* the same items, before and after the cleanup.
FoldEqual ==
  pruned => (Len(log) >= Len(orig) =>
    \A k \in 1..Len(orig) :
      /\ Meaning(SubSeq(log, 1, k)) = Meaning(SubSeq(orig, 1, k))
      /\ Cardinality(Idx(SubSeq(log, 1, k), "item")) = Cardinality(Idx(SubSeq(orig, 1, k), "item")))

\* A snapshot's usage is the meaning of the lines it covers.
SnapshotMeaningValid ==
  \A s \in Idx(log, "snapshot") :
    log[s].cov <= Len(log) => log[s].val = Meaning(SubSeq(log, 1, log[s].cov))

\* A cleanup never leaves the log without a snapshot it had. The model keeps
\* the first original, so after a second cleanup the original's newest
\* snapshot is a placeholder by design; the scan's unit tests check which
\* snapshot stays. This invariant catches a cleanup that drops every one.
NewestSnapshotKept ==
  pruned => (Idx(orig, "snapshot") # {} => Idx(log, "snapshot") # {})

\* The kept original never changes once it is kept: the first original stays.
KeptOriginalFixed == [][(origKept /\ origKept') => orig' = orig]_vars

\* Every committed line of the current log past the original (a turn's line, a
\* usage line) is in the restored log with the same seq and kind. Snapshots are
\* not committed: a restore writes them again.
TailKept ==
  \A i \in 1..Len(log) :
    (log[i].seq > Len(orig) /\ log[i].kind \notin {"snapshot", "pruned"}) =>
      \E j \in 1..Len(log') : log'[j].seq = log[i].seq /\ log'[j].kind = log[i].kind

NoCommittedLoss == [][Restore => TailKept]_vars

\* Every snapshot's offset points at the compacted line it covers.
CompactionOffsetValid ==
  \A s \in Idx(log, "snapshot") :
    log[s].cov <= Len(log) => log[s].off = CompOffAt(log, log[s].cov)

\* The original log is kept after the rename, so restore stays possible.
OriginalKept == pruned => origKept

\* Liveness: dead weight in the legacy log is eventually removed.
Dead == Prunable(log) # {}
NoDeadWeight == []( Dead => <>(~Dead) )

=============================================================================
