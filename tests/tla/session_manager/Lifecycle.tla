---------------------------- MODULE Lifecycle ----------------------------
(***************************************************************************)
(* Step: L2 lazy creation and publish.                                    *)
(*                                                                         *)
(* open(.new) touches nothing on disk. The first turn builds .tmp/{id}:  *)
(* mkdir, write line 1, fsync the log, rename to {id}, fsync the parent  *)
(* directory, and only then returns to the caller. An fx crash stops    *)
(* the sequence anywhere. A machine crash can also undo an unsynced rename,*)
(* drop an unsynced mkdir, and drop line 1 if it was not fsynced.       *)
(* Rebuild sweeps leftovers in .tmp.                                     *)
(*                                                                         *)
(* Design: system-design.md D2 and "Durable State And Schema" (publish).  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Ids

Steps == {"idle", "mem", "tmpdir", "written", "synced", "renamed", "done", "dead"}

VARIABLES
    step,    \* [Ids -> Steps]: how far the first-turn publish has got
    where,   \* [Ids -> {"none", "tmp", "visible"}]: the folder on disk
    line1,   \* [Ids -> {"none", "cached", "durable"}]: line 1 on disk
    acked    \* [Ids -> BOOLEAN]: the caller was told the save succeeded

vars == <<step, where, line1, acked>>

TypeOK ==
    /\ step \in [Ids -> Steps]
    /\ where \in [Ids -> {"none", "tmp", "visible"}]
    /\ line1 \in [Ids -> {"none", "cached", "durable"}]
    /\ acked \in [Ids -> BOOLEAN]

Init ==
    /\ step = [s \in Ids |-> "idle"]
    /\ where = [s \in Ids |-> "none"]
    /\ line1 = [s \in Ids |-> "none"]
    /\ acked = [s \in Ids |-> FALSE]

Advance(s, from, to) ==
    /\ step[s] = from
    /\ step' = [step EXCEPT ![s] = to]

OpenNew(s) ==
    /\ Advance(s, "idle", "mem")
    /\ UNCHANGED <<where, line1, acked>>

MkTmp(s) ==
    /\ Advance(s, "mem", "tmpdir")
    /\ where' = [where EXCEPT ![s] = "tmp"]
    /\ UNCHANGED <<line1, acked>>

WriteLine1(s) ==
    /\ Advance(s, "tmpdir", "written")
    /\ line1' = [line1 EXCEPT ![s] = "cached"]
    /\ UNCHANGED <<where, acked>>

FsyncLog(s) ==
    /\ Advance(s, "written", "synced")
    /\ line1' = [line1 EXCEPT ![s] = "durable"]
    /\ UNCHANGED <<where, acked>>

Rename(s) ==
    /\ Advance(s, "synced", "renamed")
    /\ where' = [where EXCEPT ![s] = "visible"]
    /\ UNCHANGED <<line1, acked>>

\* fsync of sessions/v2/ makes the rename durable; then append() returns.
FsyncDirAndAck(s) ==
    /\ Advance(s, "renamed", "done")
    /\ acked' = [acked EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<where, line1>>

\* fx dies: every unfinished first-turn publish stops; the disk keeps what it has.
ProcessCrash ==
    /\ \E s \in Ids : step[s] \notin {"idle", "done", "dead"}
    /\ step' = [s \in Ids |-> IF step[s] \in {"idle", "done"} THEN step[s] ELSE "dead"]
    /\ UNCHANGED <<where, line1, acked>>

\* Machine crash (the PowerLoss action): like an fx crash, and unsynced directory changes and unsynced
\* line 1 bytes may also be lost. An unsynced rename may be undone, and when
\* the mkdir of .tmp/{id} was never synced either, the folder may be gone
\* from both places. Unsynced line 1 bytes may vanish or survive; after the
\* reboot, whatever survived is durable.
PowerLoss ==
    \E lose \in [Ids -> BOOLEAN], gone \in [Ids -> BOOLEAN], keep \in [Ids -> BOOLEAN] :
        LET w == [s \in Ids |->
                    CASE step[s] = "renamed" /\ lose[s] -> IF gone[s] THEN "none" ELSE "tmp"
                      [] where[s] = "tmp" /\ step[s] # "done" /\ lose[s] -> "none"
                      [] OTHER -> where[s]]
        IN /\ where' = w
           /\ line1' = [s \in Ids |->
                          CASE w[s] = "none"                  -> "none"
                            [] line1[s] = "cached" /\ keep[s] -> "durable"
                            [] line1[s] = "cached"            -> "none"
                            [] OTHER                          -> line1[s]]
           /\ step' = [s \in Ids |->
                          IF step[s] \in {"idle", "done"} THEN step[s] ELSE "dead"]
           /\ UNCHANGED acked

\* rebuild(): remove a leftover .tmp folder of a first-turn publish that died.
Sweep(s) ==
    /\ step[s] = "dead"
    /\ where[s] = "tmp"
    /\ where' = [where EXCEPT ![s] = "none"]
    /\ line1' = [line1 EXCEPT ![s] = "none"]
    /\ UNCHANGED <<step, acked>>

Next ==
    \/ \E s \in Ids :
          \/ OpenNew(s)
          \/ MkTmp(s)
          \/ WriteLine1(s)
          \/ FsyncLog(s)
          \/ Rename(s)
          \/ FsyncDirAndAck(s)
          \/ Sweep(s)
    \/ ProcessCrash
    \/ PowerLoss

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A visible session always has a durable first line.
VisibleHasLine1 == \A s \in Ids : where[s] = "visible" => line1[s] = "durable"

\* An acknowledged first turn stays visible, even after a machine crash.
AckedIsVisible == \A s \in Ids : acked[s] => where[s] = "visible"

\* open(.new) and settings held before the first turn never create anything on disk.
NothingBeforeFirstTurn ==
    \A s \in Ids : step[s] \in {"idle", "mem"} => where[s] = "none"
=============================================================================
