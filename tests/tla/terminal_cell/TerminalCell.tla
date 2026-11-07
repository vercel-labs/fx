---------------------------- MODULE TerminalCell ----------------------------
(* What a terminal cell does with the zero-width units written on it after
   its base character: combining marks, zero-width joiners and spaces,
   variation selectors, and tag characters (`appendCombiningSuffix` in
   src/core/terminal/engine.zig). A cell holds at most Cap bytes of text, its
   base character and its suffix together, the size a render snapshot accepts
   (`renderSnapshot` and max_cell_text_bytes in src/core/terminal/contracts.zig).
   A unit is one codepoint; a mark that arrives in pieces across reads still
   counts as one unit.

   The same stream of units is written onto a cell of two grids: A takes it
   one unit per read, B in reads of two units. They must end alike, so the
   result never depends on where the reads cut the stream.

   Cap is scaled down here so TLC reaches it within a few units; the Zig tests
   and tests/tla/drivers/terminal_cell/driver.ts use the real 64.

   Constants select the design or a planted defect:
     Rule             "drop" keeps the cell and drops a unit that does not
                      fit; "fail" is fx before the change, where the write
                      returns an error and fx exits.
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
                                           earlier ones out *)
EXTENDS Naturals, Sequences

CONSTANTS UnitSizes, BaseSizes, N, Cap, Rule, CapIncludesBase, Bug

VARIABLES base,           \* bytes of the base character
          stream,         \* the units, as their sizes in bytes
          ai, aused,      \* grid A: next unit, bytes of suffix kept
          adrop, acol,    \* units dropped, column the cursor is in
          bi, bused, bcol,\* grid B
          alive,          \* the process is still running
          keptAfterDrop   \* a unit fit after an earlier one was dropped

vars == <<base, stream, ai, aused, adrop, acol, bi, bused, bcol, alive, keptAfterDrop>>

Streams == UNION { [1..l -> UnitSizes] : l \in 1..N }

\* Whether a unit of `u` bytes fits after `used` bytes of suffix.
HasRoom(u, used) ==
    IF CapIncludesBase THEN base + used + u <= Cap ELSE used + u <= Cap

TypeOK ==
    /\ base \in BaseSizes
    /\ stream \in [1..Len(stream) -> UnitSizes]
    /\ ai \in 1..(Len(stream) + 1) /\ bi \in 1..(Len(stream) + 1)
    /\ aused \in 0..(Cap * 2) /\ bused \in 0..(Cap * 2)
    /\ adrop \in 0..Len(stream)
    /\ acol \in Nat /\ bcol \in Nat
    /\ alive \in BOOLEAN /\ keptAfterDrop \in BOOLEAN

InitWith(b, s) ==
    /\ base = b /\ stream = s
    /\ ai = 1 /\ aused = 0 /\ adrop = 0 /\ acol = 2
    /\ bi = 1 /\ bused = 0 /\ bcol = 2
    /\ alive = TRUE /\ keptAfterDrop = FALSE

\* The same state for the next stream, for the trace check.
ResetTo(b, s) ==
    /\ base' = b /\ stream' = s
    /\ ai' = 1 /\ aused' = 0 /\ adrop' = 0 /\ acol' = 2
    /\ bi' = 1 /\ bused' = 0 /\ bcol' = 2
    /\ alive' = TRUE /\ keptAfterDrop' = FALSE

Init == \E b \in BaseSizes, s \in Streams : InitWith(b, s)

\* Grid A reads one unit.
AFeed ==
    /\ alive /\ ai <= Len(stream)
    /\ LET u == stream[ai]
           fits == HasRoom(u, aused) /\ (Bug # "stop-at-first" \/ adrop = 0)
       IN IF fits
             THEN /\ ai' = ai + 1 /\ aused' = aused + u
                  /\ keptAfterDrop' = (keptAfterDrop \/ adrop > 0)
                  /\ UNCHANGED <<adrop, acol, alive>>
             ELSE IF Rule = "fail"
                  THEN /\ alive' = FALSE
                       /\ UNCHANGED <<ai, aused, adrop, acol, keptAfterDrop>>
                  ELSE /\ ai' = ai + 1 /\ adrop' = adrop + 1
                       /\ aused' = IF Bug = "evict-earlier"
                                      THEN (IF base + u <= Cap THEN u ELSE 0)
                                      ELSE aused
                       /\ acol' = IF Bug = "drop-moves-cursor" THEN acol + 1 ELSE acol
                       /\ UNCHANGED <<alive, keptAfterDrop>>
    /\ UNCHANGED <<base, stream, bi, bused, bcol>>

\* Grid B reads two units at once, or the last one alone.
BFeed ==
    /\ alive /\ bi <= Len(stream)
    /\ LET n == IF bi = Len(stream) THEN 1 ELSE 2
           first == stream[bi]
           second == IF n = 2 THEN stream[bi + 1] ELSE 0
           whole == first + second
           f1 == HasRoom(first, bused)
           used1 == IF f1 THEN bused + first ELSE bused
           f2 == n = 2 /\ HasRoom(second, used1)
           used2 == IF f2 THEN used1 + second ELSE used1
           wholeFits == HasRoom(whole, bused)
           newUsed == IF Bug = "call-atomic"
                         THEN (IF wholeFits THEN bused + whole ELSE bused)
                         ELSE used2
           anyDropped == IF Bug = "call-atomic"
                            THEN ~wholeFits
                            ELSE (~f1 \/ (n = 2 /\ ~f2))
       IN IF anyDropped /\ Rule = "fail"
             THEN /\ alive' = FALSE /\ UNCHANGED <<bi, bused>>
             ELSE /\ bi' = bi + n /\ bused' = newUsed /\ UNCHANGED alive
    /\ UNCHANGED <<base, stream, ai, aused, adrop, acol, bcol, keptAfterDrop>>

Next == AFeed \/ BFeed

Spec == Init /\ [][Next]_vars /\ WF_vars(AFeed) /\ WF_vars(BFeed)

Done == ai > Len(stream) /\ bi > Len(stream)

\* fx keeps running however many units a cell is given.
StaysRunning == alive

\* The cell's text never passes what a render snapshot accepts.
CellWithinCap == base + aused <= Cap /\ base + bused <= Cap

\* A dropped unit does not move the cursor: the next character lands in the
\* column after the base.
CursorAligned == acol = 2 /\ bcol = 2

\* Where the reads cut the stream does not change the cell.
SplitIndependent == (Done /\ alive) => aused = bused

\* The marks a cell has kept stay.
KeepsEarlier == [][aused' >= aused /\ bused' >= bused]_vars

\* A unit that has room is kept, whatever was dropped before it.
GreedyFits ==
    [][(ai <= Len(stream) /\ ai' = ai + 1 /\ HasRoom(stream[ai], aused))
         => aused' = aused + stream[ai]]_vars

\* Every unit is read, in both grids.
FeedCompletes == <>Done

\* Witnesses that the passing config reaches the rules it checks.
NoDrop == adrop = 0
NoDropThenKeep == ~keptAfterDrop
=============================================================================
