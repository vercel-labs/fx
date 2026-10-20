------------------------------ MODULE UiStream ------------------------------
(***************************************************************************)
(* A session's UI stream in a World, as a reader in another process sees   *)
(* it while workers write it. libfx numbers each line by its place in the  *)
(* stored stream, and `stream(cursor)` reads from that place, so a live    *)
(* reader must get exactly the lines, in the order and under the cursors,  *)
(* that a replay from cursor 0 gets (DUR-38).                              *)
(*                                                                         *)
(* A worker pushes lines in order and writes them as libfx's UI writer     *)
(* does: at once when no write is in flight, and the lines pushed          *)
(* meanwhile together in the next write. A batch written with one call     *)
(* becomes visible chunk by chunk, in any order when the World writes a    *)
(* batch's chunks in parallel, as world-local does, and in order when it   *)
(* keeps a batch's order, as Vercel's World does with one request. A       *)
(* reader in another process takes each chunk once it is visible, the      *)
(* lowest place first among those it has not had, as world-local's reader *)
(* does when it polls the stream's folder.                                 *)
(*                                                                         *)
(* OneByOne is the fix for one worker: libfx writes each line before the   *)
(* next unless the World keeps a batch's order. The witness                *)
(* UiStreamWitness-Batched writes batches to a World that does not, as     *)
(* libfx did, and breaks LiveIsReplay.                                     *)
(*                                                                         *)
(* With Takeover, the worker A can freeze while a write of its own is on   *)
(* its way to the World, and the worker B takes the session over and       *)
(* writes its lines, which rank above A's. A wakes later, and the write it *)
(* had on its way lands; it writes nothing more, as libfx's worker does    *)
(* once its own clock says its lease ran out (DurableSession.tla           *)
(* LateLine). Where that late chunk goes is the World's Placement:         *)
(*                                                                         *)
(* - "start": a chunk's place is fixed when its write starts, as           *)
(*   world-local 5.1.1 fixes it by the name it gives the chunk then. A's   *)
(*   late chunk goes ahead of B's lines and moves every later line one     *)
(*   place on, under a reader that already had them                        *)
(*   (UiStreamWitness-LateLine).                                           *)
(* - "mint": the writer names the chunk just before it lands, with a name  *)
(*   after every chunk minted so far, and the chunk takes that place. A    *)
(*   writer that freezes between naming its chunk and landing it still     *)
(*   puts it ahead of the lines landed meanwhile                           *)
(*   (UiStreamWitness-StaleName): naming late is not enough.               *)
(* - "land": the writer names the place after the stream's newest chunk,   *)
(*   and the chunk lands only there. When another chunk took that place,   *)
(*   the landing fails and the writer names the next one (Name again), as  *)
(*   libfx's bundled world-local does with link(), which never replaces a  *)
(*   file. So a chunk's place is where it lands, after every chunk a       *)
(*   reader can have, even for a writer frozen between naming and landing: *)
(*   A's late chunk goes after B's lines, where readers hide it by its     *)
(*   epoch, and no cursor moves (UiStream-local-takeover, which            *)
(*   tests/tla/drivers/drive-uistream.mjs walks against the code). It also *)
(*   describes memory() and Vercel's World, whose store places a chunk as  *)
(*   it arrives (UiStream-takeover); a Name there is nothing the worker    *)
(*   does.                                                                 *)
(*                                                                         *)
(* With Fills, A's lines are the parts of a reply A had saved when it      *)
(* froze, and B is the worker that resumes the turn and ends it with that  *)
(* reply, which its engine does not stream. B's first line is its          *)
(* turn_resume; once that line is visible B reads which of A's parts       *)
(* readers show and writes the rest as its second line                     *)
(* (DurableSession.tla Commit, with ResumeFills; sdk/durable.js            *)
(* unshownReply). Readers then show each part once (FillShowsOnce) where a *)
(* late chunk lands after B's lines, so readers hide it: UiStream-fill.    *)
(* Where its place is fixed when its write starts, A's late chunk shows    *)
(* ahead of B's lines after B read the stream without it, and its part     *)
(* shows twice (UiStreamWitness-FillTwice).                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Lines,           \* how many lines A writes
    OneByOne,        \* libfx writes a line only once the one before it is visible
    WorldKeepsOrder, \* the World makes a batch's chunks visible in order
    Takeover,        \* A can freeze with a write on its way, and B take over
    TakeoverLines,   \* how many lines B writes
    Placement,       \* when a chunk's place is fixed: "start", "mint" or "land"
    Fills            \* A's lines are a saved reply's parts, whose rest B writes

ASSUME Lines \in Nat /\ TakeoverLines \in Nat
ASSUME OneByOne \in BOOLEAN /\ WorldKeepsOrder \in BOOLEAN
ASSUME Takeover \in BOOLEAN /\ Placement \in {"start", "mint", "land"}
ASSUME Fills \in BOOLEAN /\ (Fills => Takeover /\ TakeoverLines = 2)

Writers == IF Takeover THEN {"A", "B"} ELSE {"A"}
Count(w) == IF w = "A" THEN Lines ELSE TakeoverLines
\* A chunk: writer w's line n.
Chunks == {[w |-> w, n |-> n] : w \in {"A", "B"}, n \in 1..Lines + TakeoverLines}
Acts == {"Init", "Push", "Write", "Name", "Land", "Take", "Freeze", "Wake", "Read"}

VARIABLES
    pushed,    \* lines 1..pushed[w] of each worker are pushed
    sent,      \* lines 1..sent[w] have had their writes started
    inflight,  \* each worker's chunks whose write started and that are not visible yet
    starts,    \* every chunk, in the order its write started
    named,     \* the place each writer named for each of its lines, or 0
    minted,    \* how many names writers minted, with "mint"
    lands,     \* every visible chunk, in the order it became visible
    frozen,    \* "no", "frozen" while A is frozen, "woke" once it woke
    live,      \* the chunks the live reader took, in the order it took them
    read,      \* with Fills, B read the stream once its first line was visible
    found,     \* the parts of A's lines B then found readers show
    act        \* the step that led here: its name, then its writer and line

vars == <<pushed, sent, inflight, starts, named, minted, lands, frozen, live, read, found, act>>

Range(s) == {s[i] : i \in DOMAIN s}
IndexOf(s, x) == CHOOSE i \in DOMAIN s : s[i] = x
\* A visible chunk's place in the stored stream.
Place(c) == CASE Placement = "start" -> IndexOf(starts, c)
              [] Placement = "mint" -> named[c.w][c.n]
              [] Placement = "land" -> IndexOf(lands, c)
MinPlace(set) == CHOOSE c \in set : \A d \in set : Place(c) <= Place(d)
\* The stream as a replay from cursor 0 reads it now: its visible chunks in
\* place order.
Replay == [i \in 1..Len(lands) |-> CHOOSE c \in Range(lands) : Cardinality({d \in Range(lands) : Place(d) <= Place(c)}) = i]

TypeOK ==
    /\ pushed \in [{"A", "B"} -> 0..Lines + TakeoverLines]
    /\ sent \in [{"A", "B"} -> 0..Lines + TakeoverLines]
    /\ inflight \in [{"A", "B"} -> SUBSET Chunks]
    /\ starts \in Seq(Chunks) /\ lands \in Seq(Chunks) /\ live \in Seq(Chunks)
    /\ named \in [{"A", "B"} -> [1..Lines + TakeoverLines -> Nat]] /\ minted \in Nat
    /\ frozen \in {"no", "frozen", "woke"}
    /\ read \in BOOLEAN /\ found \in SUBSET (1..Lines)
    /\ act[1] \in Acts

Init ==
    /\ pushed = [w \in {"A", "B"} |-> 0]
    /\ sent = [w \in {"A", "B"} |-> 0]
    /\ inflight = [w \in {"A", "B"} |-> {}]
    /\ starts = <<>> /\ lands = <<>>
    /\ named = [w \in {"A", "B"} |-> [n \in 1..Lines + TakeoverLines |-> 0]] /\ minted = 0
    /\ frozen = "no"
    /\ live = <<>>
    /\ read = FALSE /\ found = {}
    /\ act = <<"Init">>

\* Whether w runs: A until it freezes, and B once A froze.
Runs(w) == IF w = "A" THEN frozen = "no" ELSE frozen # "no"
\* Whether w's write on its way can go on: not while A is frozen.
Goes(w) == w \in Writers /\ ~(w = "A" /\ frozen = "frozen")

\* w pushes its next line.
Push(w) ==
    /\ Runs(w)
    /\ pushed[w] < Count(w)
    \* With Fills, B's second line is the rest of the reply, which it knows
    \* only once it read the stream.
    /\ (Fills /\ w = "B" /\ pushed[w] = 1) => read
    /\ pushed' = [pushed EXCEPT ![w] = pushed[w] + 1]
    /\ UNCHANGED <<sent, inflight, starts, named, minted, lands, frozen, live, read, found>>
    /\ act' = <<"Push", w>>

\* No write of w's is in flight, so the lines it pushed since its last one
\* go out: together, or only the first of them when libfx writes one by one.
Write(w) ==
    /\ Runs(w)
    /\ inflight[w] = {}
    /\ sent[w] < pushed[w]
    /\ LET last == IF OneByOne /\ ~WorldKeepsOrder THEN sent[w] + 1 ELSE pushed[w]
           batch == [k \in 1..(last - sent[w]) |-> [w |-> w, n |-> sent[w] + k]]
       IN /\ inflight' = [inflight EXCEPT ![w] = Range(batch)]
          /\ starts' = starts \o batch
          /\ sent' = [sent EXCEPT ![w] = last]
    /\ UNCHANGED <<pushed, named, minted, lands, frozen, live, read, found>>
    /\ act' = <<"Write", w>>

\* w names a chunk of its write in flight, just before it lands it: with
\* "mint" a name after every one minted so far, with "land" the place after
\* the stream's newest chunk, again when another chunk took the one it named.
Name(w) ==
    /\ Placement # "start"
    /\ Goes(w)
    /\ \E c \in inflight[w] :
          /\ IF Placement = "mint" THEN named[c.w][c.n] = 0 ELSE named[c.w][c.n] # Len(lands) + 1
          /\ named' = [named EXCEPT ![c.w][c.n] = IF Placement = "mint" THEN minted + 1 ELSE Len(lands) + 1]
          /\ minted' = IF Placement = "mint" THEN minted + 1 ELSE minted
          /\ act' = <<"Name", w, c.n>>
    /\ UNCHANGED <<pushed, sent, inflight, starts, lands, frozen, live, read, found>>

\* One chunk of w's write in flight becomes visible: any of them when the
\* World writes them in parallel, the first when it keeps their order. A
\* frozen worker's write lands only once it wakes. A chunk lands once its
\* writer named it, and with "land" only at the place it named.
Land(w) ==
    /\ Goes(w)
    /\ inflight[w] # {}
    /\ \E c \in inflight[w] :
          /\ WorldKeepsOrder => \A d \in inflight[w] : c.n <= d.n
          /\ Placement = "mint" => named[c.w][c.n] # 0
          /\ Placement = "land" => named[c.w][c.n] = Len(lands) + 1
          /\ inflight' = [inflight EXCEPT ![w] = inflight[w] \ {c}]
          /\ lands' = Append(lands, c)
          /\ act' = <<"Land", w, c.n>>
    /\ UNCHANGED <<pushed, sent, starts, named, minted, frozen, live, read, found>>

\* A freezes with a write on its way, and B takes the session over.
Freeze ==
    /\ Takeover
    /\ frozen = "no"
    /\ inflight["A"] # {}
    /\ frozen' = "frozen"
    /\ UNCHANGED <<pushed, sent, inflight, starts, named, minted, lands, live, read, found>>
    /\ act' = <<"Freeze">>

\* A wakes; its write on its way can land again.
Wake ==
    /\ frozen = "frozen"
    /\ frozen' = "woke"
    /\ UNCHANGED <<pushed, sent, inflight, starts, named, minted, lands, live, read, found>>
    /\ act' = <<"Wake">>

\* The live reader takes the visible chunk with the lowest place it has not
\* had.
Take ==
    /\ Range(lands) \ Range(live) # {}
    /\ live' = Append(live, MinPlace(Range(lands) \ Range(live)))
    /\ UNCHANGED <<pushed, sent, inflight, starts, named, minted, lands, frozen, read, found>>
    /\ act' = <<"Take">>

\* Whether readers show visible chunk c: one of A's is hidden behind any of
\* B's placed before it, as readers hide a line whose epoch is below one
\* before it.
Shown(c) == ~(c.w = "A" /\ \E d \in Range(lands) : d.w = "B" /\ Place(d) < Place(c))
IsStart(parts) == \E k \in 0..Lines : parts = 1..k
\* The parts B's second line carries: those after the ones it found, or all
\* of them when those are not the reply's start.
Rest == IF IsStart(found) THEN (1..Lines) \ found ELSE 1..Lines
\* The parts chunk c carries: A's line n is part n, and B's second line the
\* rest; B's turn_resume carries none.
Carries(c) == IF c.w = "A" THEN {c.n} ELSE IF c.n = 2 THEN Rest ELSE {}

\* With Fills, B reads the stream once its turn_resume is visible: which of
\* A's parts readers show.
Read ==
    /\ Fills
    /\ ~read
    /\ [w |-> "B", n |-> 1] \in Range(lands)
    /\ read' = TRUE
    /\ found' = {c.n : c \in {d \in Range(lands) : d.w = "A" /\ Shown(d)}}
    /\ UNCHANGED <<pushed, sent, inflight, starts, named, minted, lands, frozen, live>>
    /\ act' = <<"Read">>

Next == (\E w \in Writers : Push(w) \/ Write(w) \/ Name(w) \/ Land(w)) \/ Freeze \/ Wake \/ Take \/ Read

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A replay from cursor 0 reads the stored stream in place order. The live
\* reader's line i is that replay's line i, now and after every later
\* landing: no line the reader already has changes its cursor.
LiveIsReplay == \A i \in 1..Len(live) : i <= Len(Replay) /\ live[i] = Replay[i]

\* With Fills, readers show each part of the reply at most once, and once B's
\* second line is visible and A has nothing on its way, exactly once.
FillShowsOnce ==
    Fills =>
        \A p \in 1..Lines :
            LET k == Cardinality({c \in Range(lands) : Shown(c) /\ p \in Carries(c)})
            IN /\ k <= 1
               /\ ([w |-> "B", n |-> 2] \in Range(lands) /\ inflight["A"] = {}) => k = 1

=============================================================================
