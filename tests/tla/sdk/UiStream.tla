------------------------------ MODULE UiStream ------------------------------
(***************************************************************************)
(* A session's UI stream in a World, as a reader in another process sees   *)
(* it while a worker writes it. libfx numbers each line by its place in    *)
(* the stored stream, and `stream(cursor)` reads from that place, so a     *)
(* live reader must get exactly the lines, in the order and under the      *)
(* cursors, that a replay from cursor 0 gets (DUR-38).                     *)
(*                                                                         *)
(* The worker pushes lines in order and writes them as libfx's UI writer   *)
(* does: at once when no write is in flight, and the lines pushed          *)
(* meanwhile together in the next write. The World gives each chunk its    *)
(* place in the stream when its write starts. A batch written with one     *)
(* call becomes visible chunk by chunk, in any order when the World writes *)
(* a batch's chunks in parallel, as world-local does, and in order when it *)
(* keeps a batch's order, as Vercel's World does with one request. A      *)
(* reader in another process takes each chunk once it is visible, the      *)
(* lowest place first among those it has not had, as world-local's reader *)
(* does when it polls the stream's folder.                                 *)
(*                                                                         *)
(* OneByOne is the fix: libfx writes each line before the next unless the *)
(* World keeps a batch's order. The witness UiStreamWitness-Batched writes *)
(* batches to a World that does not, as libfx did, and breaks LiveIsReplay.*)
(*                                                                         *)
(* One writer only: lines a replaced worker writes after its successor are *)
(* hidden by their epoch (DurableSession.tla), and the order two processes *)
(* place chunks in is the World's own.                                     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Lines,           \* how many lines the worker writes
    OneByOne,        \* libfx writes a line only once the one before it is visible
    WorldKeepsOrder  \* the World makes a batch's chunks visible in order

ASSUME Lines \in Nat /\ OneByOne \in BOOLEAN /\ WorldKeepsOrder \in BOOLEAN

VARIABLES
    pushed,    \* lines 1..pushed are pushed
    placed,    \* lines 1..placed have their place: line i is at place i
    inflight,  \* the places of the write in flight that are not visible yet
    visible,   \* the places a reader can see
    live,      \* the places the live reader took, in the order it took them
    act        \* the step that led here

vars == <<pushed, placed, inflight, visible, live, act>>

Range(s) == {s[i] : i \in DOMAIN s}
Min(set) == CHOOSE x \in set : \A y \in set : x <= y

TypeOK ==
    /\ pushed \in 0..Lines /\ placed \in 0..Lines /\ placed <= pushed
    /\ inflight \subseteq 1..Lines /\ visible \subseteq 1..Lines
    /\ live \in Seq(1..Lines)
    /\ act \in {"Init", "Push", "Write", "Land", "Take"}

Init ==
    /\ pushed = 0 /\ placed = 0
    /\ inflight = {} /\ visible = {}
    /\ live = <<>>
    /\ act = "Init"

\* The turn pushes its next line.
Push ==
    /\ pushed < Lines
    /\ pushed' = pushed + 1
    /\ UNCHANGED <<placed, inflight, visible, live>>
    /\ act' = "Push"

\* No write is in flight, so the lines pushed since the last one go out:
\* together, or only the first of them when libfx writes one by one.
Write ==
    /\ inflight = {}
    /\ placed < pushed
    /\ LET last == IF OneByOne /\ ~WorldKeepsOrder THEN placed + 1 ELSE pushed
       IN /\ inflight' = (placed + 1)..last
          /\ placed' = last
    /\ UNCHANGED <<pushed, visible, live>>
    /\ act' = "Write"

\* One chunk of the write in flight becomes visible: any of them when the
\* World writes them in parallel, the first when it keeps their order.
Land ==
    /\ inflight # {}
    /\ \E p \in inflight :
          /\ WorldKeepsOrder => p = Min(inflight)
          /\ inflight' = inflight \ {p}
          /\ visible' = visible \cup {p}
    /\ UNCHANGED <<pushed, placed, live>>
    /\ act' = "Land"

\* The live reader takes the lowest visible place it has not had.
Take ==
    /\ visible \ Range(live) # {}
    /\ live' = Append(live, Min(visible \ Range(live)))
    /\ UNCHANGED <<pushed, placed, inflight, visible>>
    /\ act' = "Take"

Next == Push \/ Write \/ Land \/ Take

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A replay from cursor 0 reads the stored stream in place order, so its
\* line i is the line at place i. The live reader's line i is that line.
LiveIsReplay == \A i \in 1..Len(live) : live[i] = i

=============================================================================
