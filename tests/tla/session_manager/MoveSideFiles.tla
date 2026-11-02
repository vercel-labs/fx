--------------------------- MODULE MoveSideFiles ---------------------------
(***************************************************************************)
(* Step: fx wiring, moving an older v2 session off its side folder (D47).  *)
(*                                                                         *)
(* An older v2 session keeps large bodies and its terminal state in       *)
(* ~/.fx/session-files/{id}/. On its first writable open fx puts each     *)
(* body as a blob, writes one batch holding the map from old handles to   *)
(* blobs and the two settings, renames the terminal folder to             *)
(* ~/.fx/terminal/{id}/, and removes the side folder. One writer at a     *)
(* time holds the session (WriterLock), and a crash can stop it between   *)
(* any two steps; the next open starts again from what the disk holds.    *)
(* A reader may resolve any old handle at any moment: through the map     *)
(* once it is written, through the side folder before.                    *)
(*                                                                         *)
(* Design: system-design.md D44 to D48.                                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Handles

VARIABLES
    side,      \* SUBSET Handles: bodies still in the side folder
    folder,    \* "present" | "removed": the side folder itself
    blobs,     \* SUBSET Handles: bodies put as blobs of the session
    mapped,    \* TRUE once the batch with the map and settings is durable
    terminal,  \* "side" | "moved": where the terminal state lives
    open       \* TRUE while a writer is running the move

vars == <<side, folder, blobs, mapped, terminal, open>>

TypeOK ==
    /\ side \subseteq Handles
    /\ folder \in {"present", "removed"}
    /\ blobs \subseteq Handles
    /\ mapped \in BOOLEAN
    /\ terminal \in {"side", "moved"}
    /\ open \in BOOLEAN

Init ==
    /\ side = Handles
    /\ folder = "present"
    /\ blobs = {}
    /\ mapped = FALSE
    /\ terminal = "side"
    /\ open = FALSE

\* A writable open takes the session; the move runs inside it.
Open ==
    /\ ~open
    /\ open' = TRUE
    /\ UNCHANGED <<side, folder, blobs, mapped, terminal>>

\* put_blob() of one side body; repeating it is harmless (content addressed).
PutBlob(h) ==
    /\ open
    /\ ~mapped
    /\ h \in side
    /\ blobs' = blobs \cup {h}
    /\ UNCHANGED <<side, folder, mapped, terminal, open>>

\* One durable batch: `set moved_files` listing every blob, and the settings.
WriteMap ==
    /\ open
    /\ ~mapped
    /\ blobs = Handles
    /\ mapped' = TRUE
    /\ UNCHANGED <<side, folder, blobs, terminal, open>>

\* Rename session-files/{id}/terminal to terminal/{id}.
MoveTerminal ==
    /\ open
    /\ mapped
    /\ terminal = "side"
    /\ terminal' = "moved"
    /\ UNCHANGED <<side, folder, blobs, mapped, open>>

\* Remove the side folder and everything left in it.
RemoveSide ==
    /\ open
    /\ mapped
    /\ terminal = "moved"
    /\ folder = "present"
    /\ folder' = "removed"
    /\ side' = {}
    /\ UNCHANGED <<blobs, mapped, terminal, open>>

\* The writer stops: a clean close or a crash between any two steps.
Stop ==
    /\ open
    /\ open' = FALSE
    /\ UNCHANGED <<side, folder, blobs, mapped, terminal>>

Done == folder = "removed"

Next ==
    \/ Open
    \/ \E h \in Handles : PutBlob(h)
    \/ WriteMap
    \/ MoveTerminal
    \/ RemoveSide
    \/ Stop

Spec == Init /\ [][Next]_vars

\* Writers keep coming back, and a step enabled again and again eventually
\* runs (a crash can stop any one open, not every open).
FairSpec == Spec /\ WF_vars(Open) /\ SF_vars(WriteMap) /\ SF_vars(MoveTerminal)
    /\ SF_vars(RemoveSide) /\ \A h \in Handles : SF_vars(PutBlob(h))

-----------------------------------------------------------------------------
(* Invariants *)

\* Every old handle resolves at every moment: through the map once it is
\* written, through the side folder before.
Resolvable ==
    \A h \in Handles : (mapped /\ h \in blobs) \/ (~mapped /\ h \in side)

\* The terminal state is never lost: the side folder goes only after it moved.
TerminalKept == folder = "removed" => terminal = "moved"

\* The map names only bodies that exist as blobs.
MapComplete == mapped => blobs = Handles

\* Liveness under FairSpec: the move eventually finishes and stays finished.
EventuallyDone == <>[]Done
=============================================================================
