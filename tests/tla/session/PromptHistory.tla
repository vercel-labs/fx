---------------------------- MODULE PromptHistory ----------------------------
(***************************************************************************)
(* The input history file, history.jsonl in the profile folder, and when  *)
(* an append compacts it (src/core/session/prompt_history_store.zig        *)
(* `Store.append` and `compactRecords`).                                   *)
(*                                                                         *)
(* An append refuses a record longer than MaxRecord, cuts an incomplete    *)
(* last line that a crash left, skips a duplicate of the workspace's       *)
(* latest record, then writes and syncs its line. When the file is then    *)
(* longer than Trigger, the append compacts it: it keeps the newest valid  *)
(* records, at most RecordLimit of them in at most Target bytes, drops     *)
(* malformed lines, and renames the result over the file. The rename can   *)
(* fail before it happens (stale: the file keeps the new line and stays    *)
(* long) or after it (indeterminate: the compacted file is in place).      *)
(*                                                                         *)
(* fx used to compact at the target itself (Trigger = Target). Once bytes  *)
(* bound, the compacted file sat within one record of the trigger and the  *)
(* next append compacted again, rereading and rewriting the whole file on  *)
(* every prompt. NoCompactAfterCompact says the append right after a       *)
(* compaction only adds its line. It holds when                            *)
(* Target + MaxRecord <= Trigger, the comptime check in the store.         *)
(*                                                                         *)
(* The state is what decides the next compaction: the file's length, the   *)
(* sizes of the newest valid records a compaction could keep, and the      *)
(* bytes of a torn last line. Older records and malformed lines only add   *)
(* to the length. tests/tla/drivers/session/history.test.ts runs the real  *)
(* binary and replays each run through PromptHistoryTrace.tla.             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
  Trigger,      \* compaction_threshold_bytes
  Target,       \* compaction_byte_limit
  RecordLimit,  \* compaction_record_limit
  MaxRecord,    \* max_record_bytes
  Sizes,        \* record sizes an append may bring, some past MaxRecord
  TornSizes,    \* bytes a crash in the middle of a write may leave
  MaxLen,       \* longest file TLC explores (Bounded)
  Faults,       \* whether a compaction's rename may fail
  Mutant        \* "none", or the planted bug the config checks

ASSUME Trigger \in Nat /\ Target \in Nat /\ MaxLen \in Nat
ASSUME RecordLimit \in Nat \ {0} /\ MaxRecord \in Nat \ {0}
(* A compaction always keeps the record the append just wrote. *)
ASSUME MaxRecord <= Target
ASSUME Sizes \subseteq Nat \ {0} /\ TornSizes \subseteq Nat \ {0}
ASSUME Faults \in BOOLEAN
ASSUME Mutant \in {"none", "compare_target", "keep_to_trigger"}

VARIABLES
  len,          \* bytes in the file, the torn line included
  tail,         \* sizes of the newest valid records, oldest first
  torn,         \* bytes of an incomplete last line, 0 when it ends in a newline
  outcome,      \* what the last step did
  prev,         \* what the step before it did
  fresh,        \* the last step that wrote a line ended in a compaction
  compactions   \* compactions so far, counted up to 2

vars == <<len, tail, torn, outcome, prev, fresh, compactions>>

Outcomes == {"none", "appended", "compacted", "stale", "indeterminate",
             "duplicate", "too_large", "torn", "restart"}
Attempts == {"compacted", "stale", "indeterminate"}
Wrote == {"appended"} \cup Attempts

(* The sum of s[i..j], halving the range so the recursion stays shallow   *)
(* on the thousand records the trace replays.                             *)
RECURSIVE SumRange(_, _, _)
SumRange(s, i, j) ==
  IF i > j THEN 0
  ELSE IF i = j THEN s[i]
  ELSE LET m == (i + j) \div 2 IN SumRange(s, i, m) + SumRange(s, m + 1, j)

Sum(s) == SumRange(s, 1, Len(s))

Min(a, b) == IF a < b THEN a ELSE b

(* The length past which an append compacts, and the bytes a compaction   *)
(* keeps. The mutants swap one for the other.                             *)
CompactPast == IF Mutant = "compare_target" THEN Target ELSE Trigger
KeepBytes == IF Mutant = "keep_to_trigger" THEN Trigger ELSE Target

(* Whether the suffix of s from i on is a compaction's result in size.    *)
Fits(s, i) ==
  /\ Len(s) - i + 1 <= RecordLimit
  /\ SumRange(s, i, Len(s)) <= KeepBytes

(* The first i in lo..hi from which s fits; s fits from hi.               *)
RECURSIVE FirstFit(_, _, _)
FirstFit(s, lo, hi) ==
  IF lo >= hi THEN hi
  ELSE LET m == (lo + hi) \div 2
       IN IF Fits(s, m) THEN FirstFit(s, lo, m) ELSE FirstFit(s, m + 1, hi)

(* compactRecords keeps the longest run of newest records that fits.      *)
Compact(s) == SubSeq(s, FirstFit(s, 1, Len(s) + 1), Len(s))

(* The newest RecordLimit records: older ones can never survive a         *)
(* compaction.                                                             *)
Newest(s) ==
  IF Len(s) > RecordLimit THEN SubSeq(s, Len(s) - RecordLimit + 1, Len(s)) ELSE s

Tails == UNION {[1..n -> 1..MaxRecord] : n \in 0..RecordLimit}

(* A file of l bytes whose newest valid records are t and whose last j    *)
(* bytes are torn; the rest is older records or malformed lines.          *)
SeedOK(l, t, j) == Len(t) <= RecordLimit /\ Sum(t) + j <= l

InitFrom(l, t, j) ==
  /\ len = l
  /\ tail = t
  /\ torn = j
  /\ outcome = "none"
  /\ prev = "none"
  /\ fresh = FALSE
  /\ compactions = 0

Init ==
  \E l \in 0..MaxLen, t \in Tails, j \in {0} \cup TornSizes :
    SeedOK(l, t, j) /\ InitFrom(l, t, j)

Step(o, l, t, j, f, c) ==
  /\ outcome' = o
  /\ prev' = outcome
  /\ len' = l
  /\ tail' = t
  /\ torn' = j
  /\ fresh' = f
  /\ compactions' = c

(* An accepted prompt of r bytes (Store.append).                          *)
AppendRecord(r) ==
  IF r > MaxRecord
  THEN Step("too_large", len, tail, torn, fresh, compactions)
  ELSE
    LET committed == len - torn + r
        written == Append(tail, r)
    IN IF committed <= CompactPast
       THEN Step("appended", committed, Newest(written), 0, FALSE, compactions)
       ELSE
         LET kept == Compact(written)
             counted == Min(compactions + 1, 2)
         IN \/ Step("compacted", Sum(kept), kept, 0, TRUE, counted)
            \/ /\ Faults
               /\ Step("stale", committed, Newest(written), 0, FALSE, compactions)
            \/ /\ Faults
               /\ Step("indeterminate", Sum(kept), kept, 0, TRUE, counted)

(* The same text as the workspace's latest record: nothing is written,    *)
(* after the torn tail is cut.                                            *)
Duplicate ==
  /\ tail # <<>>
  /\ Step("duplicate", len - torn, tail, 0, fresh, compactions)

(* A crash in the middle of an append, after it cut the torn tail: the     *)
(* file ends in j bytes of its line, without a newline.                   *)
Torn(j) == Step("torn", len - torn + j, tail, j, fresh, compactions)

(* fx starts again: launching reads the history and writes nothing.       *)
Restart == Step("restart", len, tail, torn, fresh, compactions)

Next ==
  \/ \E r \in Sizes : AppendRecord(r)
  \/ Duplicate
  \/ \E j \in TornSizes : Torn(j)
  \/ Restart

Spec == Init /\ [][Next]_vars

Bounded == len <= MaxLen

TypeOK ==
  /\ len \in Nat
  /\ tail \in Seq(1..MaxRecord)
  /\ Len(tail) <= RecordLimit
  /\ torn \in {0} \cup TornSizes
  /\ outcome \in Outcomes
  /\ prev \in Outcomes
  /\ fresh \in BOOLEAN
  /\ compactions \in 0..2

(* The append right after a compaction only adds its line.                *)
NoCompactAfterCompact ==
  [][fresh /\ outcome' \in Wrote => outcome' = "appended"]_vars

(* A compaction leaves at most Target bytes in at most RecordLimit        *)
(* records.                                                               *)
CompactedFitsTarget ==
  outcome \in {"compacted", "indeterminate"} =>
    /\ len <= Target
    /\ Len(tail) <= RecordLimit

(* Witnesses: each must be violated, which shows the state is reachable.  *)
NeverCompactedTwice == compactions < 2
NeverCountBound ==
  ~(outcome = "compacted" /\ Len(tail) = RecordLimit /\ len < Target)
NeverRetried == ~(prev = "stale" /\ outcome \in Attempts)
NeverRepaired == ~(prev = "torn" /\ outcome \in Wrote)
=============================================================================
