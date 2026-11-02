------------------------------- MODULE Fork -------------------------------
(***************************************************************************)
(* Step: L2 fork and blobs.                                               *)
(*                                                                         *)
(* A blob file lands before any line can reference it. A fork copies     *)
(* lines 2..S of its source at a turn boundary and hard-links the        *)
(* source's blobs. Deleting a session removes its folder, log and links. *)
(* Invariants: every blob a live log references exists in that session,  *)
(* unless the disk lost it there, and a fork keeps its copied prefix     *)
(* whatever later happens to its source. A lost blob damages only its   *)
(* session: a fork never copies a line that names one (D39).            *)
(*                                                                         *)
(* Design: system-design.md D5, D6 and D39.                               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Ids, Blobs, MaxLen, NoBlob

VARIABLES
    st,     \* [Ids -> {"none", "live", "deleted"}]
    lg,     \* [Ids -> Seq(entry)]: each session's log
    links,  \* [Ids -> SUBSET Blobs]: files present in {id}/blobs/
    base,   \* [Ids -> Seq(entry)]: prefix copied at fork time (<<>> for roots)
    lost    \* [Ids -> SUBSET Blobs]: blob files the disk lost in that session

vars == <<st, lg, links, base, lost>>

E(k, b) == [k |-> k, b |-> b]

Count(l, k) == Cardinality({i \in 1..Len(l) : l[i].k = k})
IsOpen(l) == Count(l, "start") > Count(l, "commit")

TypeOK ==
    /\ st \in [Ids -> {"none", "live", "deleted"}]
    /\ links \in [Ids -> SUBSET Blobs]
    /\ lost \in [Ids -> SUBSET Blobs]

Init ==
    /\ st = [s \in Ids |-> "none"]
    /\ lg = [s \in Ids |-> <<>>]
    /\ links = [s \in Ids |-> {}]
    /\ base = [s \in Ids |-> <<>>]
    /\ lost = [s \in Ids |-> {}]

Create(s) ==
    /\ st[s] = "none"
    /\ st' = [st EXCEPT ![s] = "live"]
    /\ lg' = [lg EXCEPT ![s] = <<E("created", NoBlob)>>]
    /\ UNCHANGED <<links, base, lost>>

Start(s) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ ~IsOpen(lg[s])
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("start", NoBlob))]
    /\ UNCHANGED <<st, links, base, lost>>

Commit(s) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ IsOpen(lg[s])
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("commit", NoBlob))]
    /\ UNCHANGED <<st, links, base, lost>>

\* put_blob(): the file is installed before any line can reference it.
PutBlob(s, b) ==
    /\ st[s] = "live"
    /\ b \notin links[s]
    /\ links' = [links EXCEPT ![s] = @ \cup {b}]
    /\ UNCHANGED <<st, lg, base, lost>>

\* append(item{blob}): the manager checks the blob exists in this session.
Item(s, b) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ IsOpen(lg[s])
    /\ b \in links[s]
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("item", b))]
    /\ UNCHANGED <<st, links, base, lost>>

\* append(set{blobs}): a setting may list blobs, inside a turn or outside it,
\* under the item's rule: the manager checks the blob exists in this
\* session. fx writes such lines when it moves a session off its side folder
\* (D47) and when its compactor keeps records (D50). One per session bounds
\* the states; more such lines behave as more items do.
SetBlob(s, b) ==
    /\ st[s] = "live"
    /\ Len(lg[s]) < MaxLen
    /\ Count(lg[s], "set") = 0
    /\ b \in links[s]
    /\ lg' = [lg EXCEPT ![s] = Append(@, E("set", b))]
    /\ UNCHANGED <<st, links, base, lost>>

\* open(.fork{src, at}): only at a turn boundary, and only over lines
\* whose blobs the source still has (`.last_good` ends before the first
\* that names a lost one, D39). Line 1 is new; lines 2..at are copied
\* unchanged; every source blob is hard-linked.
Fork(src, f, at) ==
    /\ st[src] = "live"
    /\ st[f] = "none"
    /\ at \in 1..Len(lg[src])
    /\ ~IsOpen(SubSeq(lg[src], 1, at))
    /\ \A i \in 2..at : lg[src][i].b # NoBlob => lg[src][i].b \in links[src]
    /\ LET copied == SubSeq(lg[src], 2, at) IN
          /\ lg' = [lg EXCEPT ![f] = <<E("created", NoBlob)>> \o copied]
          /\ base' = [base EXCEPT ![f] = copied]
    /\ links' = [links EXCEPT ![f] = links[src]]
    /\ st' = [st EXCEPT ![f] = "live"]
    /\ UNCHANGED lost

\* delete(): the folder, its log and its blob links go away.
Delete(s) ==
    /\ st[s] = "live"
    /\ st' = [st EXCEPT ![s] = "deleted"]
    /\ lg' = [lg EXCEPT ![s] = <<>>]
    /\ links' = [links EXCEPT ![s] = {}]
    /\ lost' = [lost EXCEPT ![s] = {}]
    /\ UNCHANGED base

\* The disk loses one blob file of a live session (D39).
Lose(s, b) ==
    /\ st[s] = "live"
    /\ b \in links[s]
    /\ links' = [links EXCEPT ![s] = @ \ {b}]
    /\ lost' = [lost EXCEPT ![s] = @ \cup {b}]
    /\ UNCHANGED <<st, lg, base>>

Next ==
    \E s \in Ids :
        \/ Create(s)
        \/ Start(s)
        \/ Commit(s)
        \/ Delete(s)
        \/ \E b \in Blobs : PutBlob(s, b) \/ Item(s, b) \/ SetBlob(s, b) \/ Lose(s, b)
        \/ \E f \in Ids, at \in 1..MaxLen : Fork(s, f, at)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* Every blob a live log references is present in that session, unless the
\* disk lost it there: a fork never inherits a missing reference.
RefsExist ==
    \A s \in Ids : st[s] = "live" =>
        \A i \in 1..Len(lg[s]) :
            lg[s][i].b # NoBlob => lg[s][i].b \in links[s] \cup lost[s]

\* A fork's copied prefix is intact, whatever happened to its source.
ForkKeepsPrefix ==
    \A f \in Ids : st[f] = "live" =>
        SubSeq(lg[f], 2, Len(base[f]) + 1) = base[f]

\* A fork never starts inside an open turn.
ForkAtBoundary == \A f \in Ids : ~IsOpen(base[f])

\* Line 1 of every live log is `created`.
FirstLine == \A s \in Ids : st[s] = "live" => lg[s][1].k = "created"
=============================================================================
