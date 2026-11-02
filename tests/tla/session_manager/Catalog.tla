----------------------------- MODULE Catalog -----------------------------
(***************************************************************************)
(* Step: L3 catalog (index.jsonl).                                        *)
(*                                                                         *)
(* The index is derived. Publishing a folder happens before its index    *)
(* put; delete renames the folder to .trash before its tombstone, then   *)
(* purges it. A crash can land between any two steps and forgets owed    *)
(* index writes. list() filters out entries whose folder is missing and *)
(* appends a tombstone for them (Heal). rebuild() re-derives the index   *)
(* from live folders and purges .trash, atomically under index.lock.     *)
(*                                                                         *)
(* Design: system-design.md "Concurrency And Ordering" (index) and       *)
(* "Reliability And Recovery".                                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANT Ids

VARIABLES
    dir,          \* [Ids -> {"none", "live", "trash", "gone"}]
    index,        \* a sequence of [id, op], op \in {"put", "del"}
    pending,      \* [Ids -> {"none", "put", "del"}]: index write still owed
    everDeleted   \* ghost: ids that were ever deleted

vars == <<dir, index, pending, everDeleted>>

LastOp(s) ==
    LET is == {i \in 1..Len(index) : index[i].id = s} IN
    IF is = {} THEN "none"
    ELSE index[CHOOSE i \in is : \A j \in is : j <= i].op

Indexed == {s \in Ids : LastOp(s) = "put"}
Live == {s \in Ids : dir[s] = "live"}

\* What list() returns: indexed entries whose folder exists.
Listed == {s \in Indexed : dir[s] = "live"}

TypeOK ==
    /\ dir \in [Ids -> {"none", "live", "trash", "gone"}]
    /\ pending \in [Ids -> {"none", "put", "del"}]
    /\ everDeleted \subseteq Ids

Init ==
    /\ dir = [s \in Ids |-> "none"]
    /\ index = <<>>
    /\ pending = [s \in Ids |-> "none"]
    /\ everDeleted = {}

\* First save: rename .tmp/{id} to {id}; the index put is owed next.
Publish(s) ==
    /\ dir[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "live"]
    /\ pending' = [pending EXCEPT ![s] = "put"]
    /\ UNCHANGED <<index, everDeleted>>

IndexPut(s) ==
    /\ pending[s] = "put"
    /\ index' = Append(index, [id |-> s, op |-> "put"])
    /\ pending' = [pending EXCEPT ![s] = "none"]
    /\ UNCHANGED <<dir, everDeleted>>

\* delete(): rename {id} to .trash/{id}; the tombstone is owed next.
Trash(s) ==
    /\ dir[s] = "live"
    /\ pending[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "trash"]
    /\ pending' = [pending EXCEPT ![s] = "del"]
    /\ everDeleted' = everDeleted \cup {s}
    /\ UNCHANGED index

IndexDel(s) ==
    /\ pending[s] = "del"
    /\ index' = Append(index, [id |-> s, op |-> "del"])
    /\ pending' = [pending EXCEPT ![s] = "none"]
    /\ UNCHANGED <<dir, everDeleted>>

Purge(s) ==
    /\ dir[s] = "trash"
    /\ pending[s] = "none"
    /\ dir' = [dir EXCEPT ![s] = "gone"]
    /\ UNCHANGED <<index, pending, everDeleted>>

\* A resume, or a title, workspace or language change, rewrites the entry of
\* a live session (D42). The session holds its writer lock throughout, and
\* delete needs that lock (Busy), so no Trash lands inside it. Over an entry
\* already put, a refresh changes no last op, so the spec leaves that case
\* out; over a missing one, such as a publish put a crash forgot, it heals.
Refresh(s) ==
    /\ dir[s] = "live"
    /\ LastOp(s) # "put"
    /\ index' = Append(index, [id |-> s, op |-> "put"])
    /\ UNCHANGED <<dir, pending, everDeleted>>

\* A crash forgets every owed index write.
Crash ==
    /\ \E s \in Ids : pending[s] # "none"
    /\ pending' = [s \in Ids |-> "none"]
    /\ UNCHANGED <<dir, index, everDeleted>>

\* list() self-heal: tombstone an indexed id whose folder is missing.
Heal(s) ==
    /\ s \in Indexed
    /\ dir[s] # "live"
    /\ index' = Append(index, [id |-> s, op |-> "del"])
    /\ UNCHANGED <<dir, pending, everDeleted>>

\* rebuild(): a fresh index with one put per live folder, then one del per
\* tombstoned id, each group in any order; .trash is purged. Tombstones
\* survive so a deleted id can never be re-imported or listed again. Owed
\* writes are dropped because the fresh index already reflects the folders.
Tombstoned == {s \in Ids : LastOp(s) = "del"}

Rebuild ==
    /\ LET n == Cardinality(Live)
           m == Cardinality(Tombstoned)
       IN \E order \in [1..n -> Live], gone \in [1..m -> Tombstoned] :
          /\ \A i, j \in 1..n : i # j => order[i] # order[j]
          /\ \A i, j \in 1..m : i # j => gone[i] # gone[j]
          /\ index' = [i \in 1..n |-> [id |-> order[i], op |-> "put"]]
                      \o [i \in 1..m |-> [id |-> gone[i], op |-> "del"]]
    /\ dir' = [s \in Ids |-> IF dir[s] = "trash" THEN "gone" ELSE dir[s]]
    /\ pending' = [s \in Ids |-> "none"]
    /\ UNCHANGED everDeleted

Next ==
    \/ \E s \in Ids :
          \/ Publish(s)
          \/ IndexPut(s)
          \/ Refresh(s)
          \/ Trash(s)
          \/ IndexDel(s)
          \/ Purge(s)
          \/ Heal(s)
    \/ Crash
    \/ Rebuild

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* list() never returns a session whose folder is gone.
ListedAreLive == Listed \subseteq Live

\* A deleted id never comes back, in the list or on disk.
NoResurrection ==
    \A s \in everDeleted : s \notin Listed /\ dir[s] # "live"

\* The index only ever names ids that were published.
IndexNamesPublished ==
    \A i \in 1..Len(index) : dir[index[i].id] # "none"

(* Action property: right after rebuild(), the index lists exactly the *)
(* live folders.                                                        *)
RebuildIsExact == [][Rebuild => (Indexed' = Live')]_vars
=============================================================================
