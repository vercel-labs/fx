---------------------------- MODULE TerminalCell ----------------------------
(* What a terminal cell does with the zero-width units written on it after
   its base character: combining marks, zero-width joiners and spaces,
   variation selectors, and tag characters (`appendCombiningSuffix` in
   src/core/terminal/engine.zig). A cell holds at most Cap bytes of text, its
   base character and its suffix together, the size a render snapshot accepts
   (`renderSnapshot` and max_cell_text_bytes in src/core/terminal/contracts.zig).
   A unit is one codepoint; a mark that arrives in pieces across reads still
   counts as one unit.

   The grid also keeps one pool of the distinct suffixes its cells show, at
   most 65,535 entries or 4 MiB (`max_pool_entries` and
   `max_combining_pool_bytes`). Each unit a cell keeps makes a new suffix, so
   it takes one entry, unless the pool already holds that suffix. The pool
   frees entries only on a terminal reset (ESC c), never on a clear or a
   scroll, so a long run of different marks fills it for good. The model
   leaves out the suffixes that are already in the pool, which cost no
   entry and are kept even when it is full (the inline tests in engine.zig
   cover them), and counts every kept unit as one entry. The cap is checked
   first: a unit that does not fit the cell is dropped without an entry.

   The same stream of units is written onto a cell of two grids: A takes it
   one unit per read, B in reads of two units. They must end alike, so the
   result never depends on where the reads cut the stream.

   Cap is scaled down here so TLC reaches it within a few units, and so is the
   pool: the pool has PoolRoom free entries when the cell starts, for each
   room in PoolRooms. The Zig tests and tests/tla/drivers/terminal_cell/driver.ts
   use the real 64 and the real pool.

   Constants select the design or a planted defect:
     Rule             "drop" keeps the cell and drops a unit that does not
                      fit; "fail" is fx before the cap, where the write
                      returns an error and fx exits.
     PoolRule         what a unit that fits the cell does when the pool is
                      full. "drop" drops it and fx keeps running; "fail"
                      is fx before the pool change, where the write returns
                      `CombiningPoolCapacityExceeded` and fx exits.
     PoolRooms        the free pool entries the cell can start with.
     CapIncludesBase  TRUE caps base plus suffix; FALSE caps the suffix alone,
                      as fx did, so base plus suffix can pass the snapshot
                      limit.
     Bug              "none" is the design. The others plant one defect:
                        drop-moves-cursor  a dropped unit advances the cursor
                        call-atomic        a read that does not fit whole is
                                           dropped whole
                        stop-at-first      after one drop, every later unit is
                                           dropped
                        evict-earlier      a unit that does not fit pushes the
                                           earlier ones out
                        pool-evicts-earlier  a unit the full pool drops
                                           pushes the earlier ones out
                        pool-drop-moves-cursor  a unit the full pool drops
                                           advances the cursor *)
EXTENDS Naturals, Sequences

CONSTANTS UnitSizes, BaseSizes, N, Cap, Rule, PoolRule, PoolRooms, CapIncludesBase, Bug

VARIABLES base,           \* bytes of the base character
          stream,         \* the units, as their sizes in bytes
          ai, aused,      \* grid A: next unit, bytes of suffix kept
          adrop, acol,    \* units dropped, column the cursor is in
          room0,          \* free pool entries the cell started with
          aroom, apdrop,  \* free pool entries now, units the full pool dropped
          bi, bused, bcol,\* grid B
          broom,
          alive,          \* the process is still running
          keptAfterDrop   \* a unit fit after an earlier one was dropped

vars == <<base, stream, ai, aused, adrop, acol, room0, aroom, apdrop,
          bi, bused, bcol, broom, alive, keptAfterDrop>>

Streams == UNION { [1..l -> UnitSizes] : l \in 1..N }

\* Whether a unit of `u` bytes fits after `used` bytes of suffix.
HasRoom(u, used) ==
    IF CapIncludesBase THEN base + used + u <= Cap ELSE used + u <= Cap

TypeOK ==
    /\ base \in BaseSizes
    /\ stream \in [1..Len(stream) -> UnitSizes]
    /\ ai \in 1..(Len(stream) + 1) /\ bi \in 1..(Len(stream) + 1)
    /\ aused \in 0..(Cap * 2) /\ bused \in 0..(Cap * 2)
    /\ adrop \in 0..Len(stream) /\ apdrop \in 0..Len(stream)
    /\ acol \in Nat /\ bcol \in Nat
    /\ room0 \in Nat /\ aroom \in Nat /\ broom \in Nat
    /\ alive \in BOOLEAN /\ keptAfterDrop \in BOOLEAN

InitWith(b, s, r) ==
    /\ base = b /\ stream = s
    /\ ai = 1 /\ aused = 0 /\ adrop = 0 /\ acol = 2 /\ room0 = r /\ aroom = r /\ apdrop = 0
    /\ bi = 1 /\ bused = 0 /\ bcol = 2 /\ broom = r
    /\ alive = TRUE /\ keptAfterDrop = FALSE

\* The same state for the next stream, for the trace check.
ResetTo(b, s, r) ==
    /\ base' = b /\ stream' = s
    /\ ai' = 1 /\ aused' = 0 /\ adrop' = 0 /\ acol' = 2 /\ room0' = r /\ aroom' = r /\ apdrop' = 0
    /\ bi' = 1 /\ bused' = 0 /\ bcol' = 2 /\ broom' = r
    /\ alive' = TRUE /\ keptAfterDrop' = FALSE

Init == \E b \in BaseSizes, s \in Streams, r \in PoolRooms : InitWith(b, s, r)

\* Grid A reads one unit. A unit is kept when it fits the cell and the pool
\* has an entry for it. One that does not fit the cell is dropped first, and
\* takes no entry. One that fits the cell and finds the pool full is dropped
\* too (PoolRule "drop") or ends the process (PoolRule "fail").
AFeed ==
    /\ alive /\ ai <= Len(stream)
    /\ LET u == stream[ai]
           cellFits == HasRoom(u, aused) /\ (Bug # "stop-at-first" \/ adrop = 0)
           poolFits == aroom > 0
       IN IF cellFits /\ poolFits
             THEN /\ ai' = ai + 1 /\ aused' = aused + u /\ aroom' = aroom - 1
                  /\ keptAfterDrop' = (keptAfterDrop \/ adrop > 0)
                  /\ UNCHANGED <<adrop, acol, apdrop, alive>>
             ELSE IF (~cellFits /\ Rule = "fail") \/ (cellFits /\ ~poolFits /\ PoolRule = "fail")
                  THEN /\ alive' = FALSE
                       /\ UNCHANGED <<ai, aused, adrop, acol, aroom, apdrop, keptAfterDrop>>
                  ELSE /\ ai' = ai + 1 /\ adrop' = adrop + 1
                       /\ apdrop' = IF cellFits THEN apdrop + 1 ELSE apdrop
                       /\ aused' = IF Bug = "evict-earlier"
                                      THEN (IF base + u <= Cap THEN u ELSE 0)
                                   ELSE IF Bug = "pool-evicts-earlier" /\ cellFits
                                      THEN 0
                                   ELSE aused
                       /\ acol' = IF \/ Bug = "drop-moves-cursor"
                                     \/ (Bug = "pool-drop-moves-cursor" /\ cellFits)
                                     THEN acol + 1 ELSE acol
                       /\ UNCHANGED <<alive, keptAfterDrop, aroom>>
    /\ UNCHANGED <<base, stream, room0, bi, bused, bcol, broom>>

\* Grid B reads two units at once, or the last one alone. Its units go through
\* the same checks one after the other, so the pool entries the first takes are
\* not there for the second.
BFeed ==
    /\ alive /\ bi <= Len(stream)
    /\ LET n == IF bi = Len(stream) THEN 1 ELSE 2
           first == stream[bi]
           second == IF n = 2 THEN stream[bi + 1] ELSE 0
           whole == first + second
           c1 == HasRoom(first, bused)
           p1 == broom > 0
           k1 == c1 /\ p1
           used1 == IF k1 THEN bused + first ELSE bused
           room1 == IF k1 THEN broom - 1 ELSE broom
           c2 == n = 2 /\ HasRoom(second, used1)
           p2 == n = 2 /\ room1 > 0
           k2 == c2 /\ p2
           used2 == IF k2 THEN used1 + second ELSE used1
           room2 == IF k2 THEN room1 - 1 ELSE room1
           wholeFits == HasRoom(whole, bused) /\ broom >= n
           newUsed == IF Bug = "call-atomic"
                         THEN (IF wholeFits THEN bused + whole ELSE bused)
                         ELSE used2
           newRoom == IF Bug = "call-atomic"
                         THEN (IF wholeFits THEN broom - n ELSE broom)
                         ELSE room2
           capDropped == IF Bug = "call-atomic"
                            THEN ~HasRoom(whole, bused)
                            ELSE (~c1 \/ (n = 2 /\ ~c2))
           poolDropped == IF Bug = "call-atomic"
                             THEN HasRoom(whole, bused) /\ broom < n
                             ELSE ((c1 /\ ~p1) \/ (n = 2 /\ c2 /\ ~p2))
       IN IF (capDropped /\ Rule = "fail") \/ (poolDropped /\ PoolRule = "fail")
             THEN /\ alive' = FALSE /\ UNCHANGED <<bi, bused, broom>>
             ELSE /\ bi' = bi + n /\ bused' = newUsed /\ broom' = newRoom
                  /\ UNCHANGED alive
    /\ UNCHANGED <<base, stream, ai, aused, adrop, acol, room0, aroom, apdrop, bcol, keptAfterDrop>>

Next == AFeed \/ BFeed

Spec == Init /\ [][Next]_vars /\ WF_vars(AFeed) /\ WF_vars(BFeed)

Done == ai > Len(stream) /\ bi > Len(stream)

\* fx keeps running however many units a cell is given and however full the
\* pool is.
StaysRunning == alive

\* The cell's text never passes what a render snapshot accepts.
CellWithinCap == base + aused <= Cap /\ base + bused <= Cap

\* The pool never takes more entries than it had room for, and every unit grid
\* A has read is either kept, which takes one entry, or dropped and counted.
PoolWithinBound == aroom <= room0 /\ broom <= room0
PoolAccounted == (room0 - aroom) + adrop = ai - 1

\* A dropped unit does not move the cursor: the next character lands in the
\* column after the base.
CursorAligned == acol = 2 /\ bcol = 2

\* Where the reads cut the stream does not change the cell.
SplitIndependent == (Done /\ alive) => aused = bused

\* The marks a cell has kept stay.
KeepsEarlier == [][aused' >= aused /\ bused' >= bused]_vars

\* A unit that has room in the cell and an entry in the pool is kept, whatever
\* was dropped before it.
GreedyFits ==
    [][(ai <= Len(stream) /\ ai' = ai + 1 /\ HasRoom(stream[ai], aused) /\ aroom > 0)
         => aused' = aused + stream[ai]]_vars

\* The units the pool dropped are counted with the others.
PoolDropsCounted == apdrop <= adrop

\* Every unit is read, in both grids.
FeedCompletes == <>Done

\* Witnesses that the passing config reaches the rules it checks.
NoDrop == adrop = 0
NoDropThenKeep == ~keptAfterDrop
NoPoolDrop == apdrop = 0
=============================================================================
