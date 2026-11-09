------------------------------ MODULE SessionWrite ------------------------------
(***************************************************************************)
(* How the writes of one session list the compactor's records (D50;       *)
(* `src/core/session/session_adapter.zig`: `Session.write`, `recordsDue`,  *)
(* `recordsWritten`, `BlobHost.putRecord`).                                *)
(*                                                                         *)
(* The compactor keeps each record as a blob and adds its hash to the      *)
(* host's list of records not yet listed. Every write of the session takes *)
(* the records due, lists them in its batch, appends the batch, and then   *)
(* clears them from the front of that list. Main's compaction line cites   *)
(* the records, so it must never land before they are listed. Writes run   *)
(* on more than one thread: main's own, and each subagent's, whose finish  *)
(* line goes to main's session. The compactor runs on main's thread, so it *)
(* adds records only between main's writes, but a subagent's write can be  *)
(* in flight while it does.                                                *)
(*                                                                         *)
(* With Locked, a write holds one lock of the session from before it takes *)
(* the due records until after it clears them. Without it, as fx was       *)
(* before, two writes can take the same records: both list them, and the   *)
(* second clear removes more than the list holds, the panic "start index N *)
(* is larger than end index 0" (NoStaleRemoval).                           *)
(*                                                                         *)
(* A record is a number, the order it was added in. With Faults, an append *)
(* can fail: nothing lands and the records stay due for the next write.    *)
(* Mutant plants one bug for a config to catch:                            *)
(*   "unlock_after_take"  the lock is let go once the records are taken    *)
(*   "clear_all"          a clear empties the whole list                   *)
(*   "clear_on_failure"   a failed append still clears its records         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Writers,    \* the session's writers, Main among them
  Main,       \* main's thread, which also runs the compactor
  MaxRecords, \* records the compactor keeps in one behavior
  MaxWrites,  \* writes each writer makes
  Locked,     \* one write of the session at a time
  Faults,     \* an append can fail
  Mutant

ASSUME Main \in Writers

VARIABLES
  added,   \* records added and not yet cleared, in order (`records_added`)
  puts,    \* records kept so far: 1..puts
  gen,     \* `records_generation`
  written, \* `records_written`
  lock,    \* the write lock's holder, or "none"
  pc,      \* each writer's step
  due,     \* each writer's due records, <<>> for none
  dueGen,  \* the generation its due records had
  writes,  \* writes each writer finished
  log,     \* the appended batches: [writer, listed, cites]
  crashed, \* a clear removed more records than the list held
  failedDue \* records a failed append had taken

vars == <<added, puts, gen, written, lock, pc, due, dueGen, writes, log, crashed, failedDue>>

Range(s) == {s[i] : i \in DOMAIN s}

(* Main's write cites every record kept so far: its compaction line names *)
(* them. A subagent's finish line cites none.                             *)
Cites(w) == IF w = Main THEN 1..puts ELSE {}

Steps == {"idle", "take", "append", "clear", "release"}

TypeOK ==
  /\ added \in Seq(1..MaxRecords)
  /\ puts \in 0..MaxRecords
  /\ lock \in Writers \cup {"none"}
  /\ pc \in [Writers -> Steps]
  /\ writes \in [Writers -> 0..MaxWrites]
  /\ crashed \in BOOLEAN

Init ==
  /\ added = <<>>
  /\ puts = 0
  /\ gen = 0
  /\ written = 0
  /\ lock = "none"
  /\ pc = [w \in Writers |-> "idle"]
  /\ due = [w \in Writers |-> <<>>]
  /\ dueGen = [w \in Writers |-> 0]
  /\ writes = [w \in Writers |-> 0]
  /\ log = <<>>
  /\ crashed = FALSE
  /\ failedDue = {}

(* `putRecord`: the compactor keeps a record, between main's writes. *)
PutRecord ==
  /\ ~crashed
  /\ puts < MaxRecords
  /\ pc[Main] = "idle"
  /\ puts' = puts + 1
  /\ added' = Append(added, puts + 1)
  /\ gen' = gen + 1
  /\ UNCHANGED <<written, lock, pc, due, dueGen, writes, log, crashed, failedDue>>

(* A write starts. With the lock it waits until no other write holds it. *)
Begin(w) ==
  /\ ~crashed
  /\ pc[w] = "idle"
  /\ writes[w] < MaxWrites
  /\ IF Locked THEN lock = "none" /\ lock' = w ELSE UNCHANGED lock
  /\ pc' = [pc EXCEPT ![w] = "take"]
  /\ UNCHANGED <<added, puts, gen, written, due, dueGen, writes, log, crashed, failedDue>>

(* `recordsDue`: a copy of the records added since the last line that    *)
(* listed them, under the host's mutex, which it then lets go of.        *)
TakeDue(w) ==
  /\ ~crashed
  /\ pc[w] = "take"
  /\ due' = [due EXCEPT ![w] = IF gen = written THEN <<>> ELSE added]
  /\ dueGen' = [dueGen EXCEPT ![w] = gen]
  /\ pc' = [pc EXCEPT ![w] = "append"]
  /\ IF Mutant = "unlock_after_take" /\ lock = w THEN lock' = "none" ELSE UNCHANGED lock
  /\ UNCHANGED <<added, puts, gen, written, writes, log, crashed, failedDue>>

(* The batch, its records lines first, lands in the log, or the append   *)
(* fails and nothing lands.                                              *)
AppendBatch(w) ==
  /\ ~crashed
  /\ pc[w] = "append"
  /\ \/ /\ log' = Append(log, [writer |-> w, listed |-> due[w], cites |-> Cites(w)])
        /\ pc' = [pc EXCEPT ![w] = "clear"]
        /\ UNCHANGED failedDue
     \/ /\ Faults
        /\ UNCHANGED log
        /\ pc' = [pc EXCEPT ![w] = IF Mutant = "clear_on_failure" THEN "clear" ELSE "release"]
        /\ failedDue' = failedDue \cup Range(due[w])
  /\ UNCHANGED <<added, puts, gen, written, lock, due, dueGen, writes, crashed>>

(* `recordsWritten`: the listed records leave the front of the list. *)
Clear(w) ==
  /\ ~crashed
  /\ pc[w] = "clear"
  /\ LET n == Len(due[w]) IN
       IF n = 0 THEN UNCHANGED <<added, written, crashed>>
       ELSE IF Mutant = "clear_all" THEN
         /\ added' = <<>>
         /\ written' = dueGen[w]
         /\ UNCHANGED crashed
       ELSE IF n > Len(added) THEN
         /\ crashed' = TRUE
         /\ UNCHANGED <<added, written>>
       ELSE
         /\ added' = SubSeq(added, n + 1, Len(added))
         /\ written' = dueGen[w]
         /\ UNCHANGED crashed
  /\ pc' = [pc EXCEPT ![w] = "release"]
  /\ UNCHANGED <<puts, gen, lock, due, dueGen, writes, log, failedDue>>

Release(w) ==
  /\ ~crashed
  /\ pc[w] = "release"
  /\ lock' = IF lock = w THEN "none" ELSE lock
  /\ pc' = [pc EXCEPT ![w] = "idle"]
  /\ due' = [due EXCEPT ![w] = <<>>]
  /\ writes' = [writes EXCEPT ![w] = writes[w] + 1]
  /\ UNCHANGED <<added, puts, gen, written, dueGen, log, crashed, failedDue>>

Next ==
  \/ PutRecord
  \/ \E w \in Writers : Begin(w) \/ TakeDue(w) \/ AppendBatch(w) \/ Clear(w) \/ Release(w)

Spec == Init /\ [][Next]_vars

Listed == UNION {Range(log[i].listed) : i \in DOMAIN log}

(* No clear removes more records than the list holds: the panic. *)
NoStaleRemoval == ~crashed

(* A record leaves the list only once a batch listed it. *)
ClearedWereListed == \A r \in (1..puts) \ Range(added) : r \in Listed

(* No record is listed by two batches. *)
ListedOnce ==
  \A i, j \in DOMAIN log : i # j => Range(log[i].listed) \cap Range(log[j].listed) = {}

(* The line that cites records never lands before they are listed (D50). *)
CitedListed ==
  \A i \in DOMAIN log :
    log[i].cites \subseteq UNION {Range(log[j].listed) : j \in 1..i}

(* Witnesses: each must be violated, so the case it names is reachable.   *)
(* A record arrives while a subagent's write holds its due records.       *)
NeverAddedDuringWrite ==
  ~\E w \in Writers \ {Main} : pc[w] \in {"append", "clear"} /\ due[w] # <<>> /\ Len(added) > Len(due[w])
(* A write waits behind another that holds the due records.               *)
NeverWaitsBehindDue ==
  ~\E w, v \in Writers : w # v /\ pc[w] = "idle" /\ writes[w] < MaxWrites /\ lock = v /\ due[v] # <<>>
(* A failed append leaves its records due, and a later batch lists them.  *)
NeverRelistedAfterFailure == failedDue \cap Listed = {}
=============================================================================
