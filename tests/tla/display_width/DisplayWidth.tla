---------------------------- MODULE DisplayWidth ----------------------------
(***************************************************************************)
(* How the composer measures Thai text and where it puts the cursor.       *)
(*                                                                         *)
(* fx measures each code point with runeWidth                              *)
(* (src/core/shared/display_width.zig), places the cursor at the sum of    *)
(* the widths before it (src/ui/input/visual_layout.zig terminalColumn),   *)
(* and moves and deletes by nextCharacterEnd and previousCharacterStart    *)
(* (src/core/input/text_boundaries.zig), which take one unit and every     *)
(* zero-width unit after it. The terminal draws a nonspacing mark on the   *)
(* cell before it.                                                         *)
(*                                                                         *)
(* The text is a sequence of code point classes:                           *)
(*   base        a spacing Thai character, such as a consonant or a lead   *)
(*               vowel                                                     *)
(*   mark        a Thai nonspacing mark: U+0E31, U+0E34-U+0E3A,            *)
(*               U+0E47-U+0E4E                                             *)
(*   am          U+0E33 SARA AM, which is spacing                          *)
(*   ascii       a printable ASCII character                               *)
(*   wide        an East Asian wide character                              *)
(*   latin_mark  a Latin combining mark, such as U+0301                    *)
(* and a drawn U+25CC DOTTED CIRCLE, class "circle", which only the        *)
(* painter writes.                                                         *)
(*                                                                         *)
(* Rule picks fx's width and boundary rules:                               *)
(*   "fixed"          the change: Thai nonspacing marks measure 0 cells    *)
(*   "today"          fx before it: each Thai mark measures 1 cell         *)
(*   "sara-am"        planted bug: SARA AM measured as a mark, as a table  *)
(*                    that ran U+0E31-U+0E3A would                         *)
(*   "split-cluster"  planted bug: nextCharacterEnd stops after one unit   *)
(*                                                                         *)
(* A nonspacing mark with no base character before it has nothing to sit   *)
(* on. It comes first in the draft, or first after a newline; the model    *)
(* has one line, so it is the first unit of the text (BareAt). The prompt's *)
(* space cell is not a base. Bare picks what fx does with it                *)
(* (src/ui/input/visual_layout.zig peekRawUnit, src/ui/footer/              *)
(* input_presentation.zig appendLayoutUnitContent):                         *)
(*   "dotted"            the change: the layout gives the mark one cell and *)
(*                       the painter writes U+25CC before it, so the mark   *)
(*                       and the marks after it stack on the circle         *)
(*   "joins-prefix"      fx before it: the mark measures 0 cells and lands  *)
(*                       on the prompt's space cell                         *)
(*   "dotted-uncounted"  planted bug: the painter writes the circle but the *)
(*                       layout still counts 0 cells for the mark           *)
(*                                                                         *)
(* A terminal cell holds at most Cap bytes of text, its base character and  *)
(* the marks on it together. The model scales Cap down so TLC reaches it;   *)
(* the code's limit is 64 (src/core/terminal/engine.zig                     *)
(* appendCombiningSuffix, tests/tla/terminal_cell/TerminalCell.tla). Every  *)
(* class has its UTF-8 size (Bytes). A mark that reaches the screen is kept *)
(* when its bytes fit the room left on the cell. Limit picks what the       *)
(* engine does with one that does not:                                      *)
(*   "drop"    the change, stacked on the engine's limit: the mark is       *)
(*             dropped, the cell stays, a later mark that fits is kept, and *)
(*             the step goes on                                             *)
(*   "refuse"  fx before it: the engine fails the step, which ends fx       *)
(*   "keep"    planted bug: no limit, so a cell can hold more than Cap      *)
(*                                                                         *)
(* The composer wraps its text into rows of Cols cells, the cells after    *)
(* its two-cell prefix: Cols is 0 in a window two columns wide or          *)
(* narrower, where a row has no content cells. A unit is drawn only when   *)
(* a row has the cells for it, and a mark only with its base, so a row     *)
(* with no content cells draws nothing, no mark included. Two steps decide *)
(* whether the marks on a character whose cell ends at the right margin    *)
(* reach the screen: the row builder must keep them on the full row        *)
(* (src/ui/footer/input_presentation.zig appendLayoutUnit), and, because   *)
(* fx paints with autowrap off, the painter must turn autowrap on while it *)
(* writes them, or the terminal puts them on another cell                  *)
(* (src/core/terminal/engine.zig diffBand). The row builder also tracks    *)
(* whether the last unit with cells went undrawn                           *)
(* (omitted_positive_unit), and drops the marks after it. Margin picks the *)
(* behavior:                                                               *)
(*   "fixed"            the change: both steps, for one-cell and two-cell *)
(*                      characters, and a row with no content cells starts *)
(*                      with the flag set                                  *)
(*   "row-drops"        fx before it: the row builder dropped every        *)
(*                      zero-width unit after a full row, so the marks on  *)
(*                      any character in the last column vanished; a row   *)
(*                      with no content cells drew nothing                 *)
(*   "wide-only-guard"  planted bug: the row keeps the marks but only      *)
(*                      two-cell characters get the painter's guard        *)
(*   "cell-less-keeps"  planted bug: the row builder returns before it     *)
(*                      sets the flag for a unit it cannot draw, so on a   *)
(*                      row with no content cells the marks of every       *)
(*                      undrawn character land on the prefix cell          *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS Rule, MaxLen, Cols, Margin, Bare, Limit, Cap

Classes == {"base", "mark", "am", "ascii", "wide", "latin_mark"}

IsMark(c) == c \in {"mark", "latin_mark"}

\* The UTF-8 bytes of a code point of each class, which is what a cell holds.
Bytes(c) ==
    CASE c = "ascii" -> 1
      [] c = "latin_mark" -> 2
      [] OTHER -> 3

\* U+25CC takes three bytes.
CircleBytes == 3

VARIABLES text, cursor, col
vars == <<text, cursor, col>>

\* A nonspacing mark with no base character before it: the first unit of the
\* draft, as a mark.
BareAt(t, i) == i = 1 /\ IsMark(t[1])

\* The cells fx's runeWidth and layout give t[i].
FxWidth(t, i) ==
    CASE t[i] = "mark" /\ Rule = "today" -> 1
      [] BareAt(t, i) -> IF Bare = "dotted" THEN 1 ELSE 0
      [] IsMark(t[i]) -> 0
      [] t[i] = "am" -> IF Rule = "sara-am" THEN 0 ELSE 1
      [] t[i] = "wide" -> 2
      [] OTHER -> 1

\* The cells the terminal gives t[i]: a bare mark has a cell exactly when the
\* painter writes the circle for it.
TermWidth(t, i) ==
    CASE BareAt(t, i) -> IF Bare = "joins-prefix" THEN 0 ELSE 1
      [] IsMark(t[i]) -> 0
      [] t[i] = "wide" -> 2
      [] OTHER -> 1

\* The column after the first i units, as fx counts it and as the terminal
\* draws it. Columns count from the first cell after the composer's prefix.
RECURSIVE FxCol(_, _)
FxCol(t, i) == IF i = 0 THEN 0 ELSE FxCol(t, i - 1) + FxWidth(t, i)

RECURSIVE TermCol(_, _)
TermCol(t, i) == IF i = 0 THEN 0 ELSE TermCol(t, i - 1) + TermWidth(t, i)

\* nextCharacterEnd: one unit, then every unit fx measures as zero cells.
RECURSIVE SkipZero(_, _)
SkipZero(t, j) == IF j < Len(t) /\ FxWidth(t, j + 1) = 0 THEN SkipZero(t, j + 1) ELSE j

NextEnd(t, i) ==
    IF i >= Len(t) THEN Len(t)
    ELSE IF Rule = "split-cluster" THEN i + 1
    ELSE SkipZero(t, i + 1)

\* previousCharacterStart: walk from the start by NextEnd.
RECURSIVE PrevFrom(_, _, _)
PrevFrom(t, from, e) == IF NextEnd(t, from) >= e THEN from ELSE PrevFrom(t, NextEnd(t, from), e)

PrevStart(t, e) == IF e = 0 THEN 0 ELSE PrevFrom(t, 0, e)

\* Every offset the cursor can stop at by moving from the start.
RECURSIVE StopsFrom(_, _)
StopsFrom(t, i) == IF i >= Len(t) THEN {Len(t)} ELSE {i} \cup StopsFrom(t, NextEnd(t, i))

Stops(t) == StopsFrom(t, 0)

\* What the terminal shows of t on the cells fx meant. fx lays the units out
\* in rows of Cols cells: a unit that does not fit starts the next row, and a
\* zero-width unit stays on its base's row. A unit with cells is drawn only
\* when it fits a row, which no unit does when Cols is 0. A zero-width unit
\* is lost from its base when that base ends at the right margin and one of
\* the two steps above fails for it, or when the last unit with cells went
\* undrawn: `undrawn` is the row builder's omitted_positive_unit. `used`
\* counts the cells of the current row, and `base` is the width of the last
\* unit with cells on it (0 before any). `room` is the bytes left on the cell
\* the next mark lands on: the cell of the last unit with cells, or the
\* prompt's space cell (one byte) before any.
LostAtMargin(w) ==
    \/ Margin = "row-drops"
    \/ Margin = "wide-only-guard" /\ w # 2

\* A unit of width w is drawn when a row has the cells for it.
Drawn(w) == w <= Cols

\* The flag when a row starts. A row with no content cells starts with it
\* set, so the marks of the units it cannot draw are dropped.
RowStartUndrawn == Cols = 0 /\ Margin # "cell-less-keeps"

\* The flag after a unit with cells. In the "cell-less-keeps" bug the row
\* builder returns before it sets the flag on a row with no content cells.
AfterCells(undrawn, w) ==
    IF Cols = 0 /\ Margin = "cell-less-keeps" THEN undrawn ELSE ~Drawn(w)

\* The picture of a unit with cells: a bare mark comes with its circle.
Picture(t, i) == IF BareAt(t, i) THEN <<"circle", t[i]>> ELSE <<t[i]>>

\* The bytes a unit with cells puts on its cell.
CellBytes(t, i) == IF BareAt(t, i) THEN CircleBytes + Bytes(t[i]) ELSE Bytes(t[i])

\* The sequence shown, whether the engine failed a step, whether a cell holds
\* more than Cap, and how many marks the limit dropped.
RECURSIVE ShownFrom(_, _, _, _, _, _)
ShownFrom(t, i, used, base, undrawn, room) ==
    IF i > Len(t) THEN [seq |-> <<>>, fail |-> FALSE, over |-> FALSE, dropped |-> 0]
    ELSE IF FxWidth(t, i) = 0
    THEN LET reaches == ~(undrawn \/ (base > 0 /\ used = Cols /\ LostAtMargin(base)))
             fits == Bytes(t[i]) <= room
             kept == reaches /\ (fits \/ Limit = "keep")
             refused == reaches /\ ~fits /\ Limit = "refuse"
             dropped == reaches /\ ~fits /\ Limit = "drop"
             rest == ShownFrom(t, i + 1, used, base, undrawn, IF kept THEN room - Bytes(t[i]) ELSE room)
         IN [seq |-> (IF kept THEN <<t[i]>> ELSE <<>>) \o rest.seq,
             fail |-> refused \/ rest.fail,
             over |-> (kept /\ ~fits) \/ rest.over,
             dropped |-> (IF dropped THEN 1 ELSE 0) + rest.dropped]
    ELSE LET w == FxWidth(t, i)
             start == IF used + w > Cols THEN 0 ELSE used
             drawn == Drawn(w)
             rest == ShownFrom(t, i + 1, start + w, w, AfterCells(undrawn, w),
                               IF drawn THEN Cap - CellBytes(t, i) ELSE Cap - 1)
         IN [seq |-> (IF drawn THEN Picture(t, i) ELSE <<>>) \o rest.seq,
             fail |-> rest.fail,
             over |-> rest.over,
             dropped |-> rest.dropped]

Shown(t) == ShownFrom(t, 1, 0, 0, RowStartUndrawn, Cap - 1)

\* The cells a unit takes in what the terminal must show: a mark with no base
\* always takes one, whatever Bare says.
WantedWidth(t, i) == IF BareAt(t, i) THEN 1 ELSE FxWidth(t, i)

\* What the terminal must show of t: a unit with cells when a row has the
\* cells for it, a bare mark on its circle, a mark when its base is drawn and
\* the cell has the room for it. `ok` is whether the last unit with cells is
\* drawn, and `room` the bytes left on its cell.
RECURSIVE WantedFrom(_, _, _, _)
WantedFrom(t, i, ok, room) ==
    IF i > Len(t) THEN <<>>
    ELSE IF WantedWidth(t, i) = 0
    THEN LET fits == Bytes(t[i]) <= room
             kept == ok /\ fits
         IN (IF kept THEN <<t[i]>> ELSE <<>>)
            \o WantedFrom(t, i + 1, ok, IF kept THEN room - Bytes(t[i]) ELSE room)
    ELSE LET d == Drawn(WantedWidth(t, i))
         IN (IF d THEN Picture(t, i) ELSE <<>>)
            \o WantedFrom(t, i + 1, d, Cap - CellBytes(t, i))

Wanted(t) == WantedFrom(t, 1, Cols > 0, Cap - 1)

Insert(t, i, c) == SubSeq(t, 1, i) \o <<c>> \o SubSeq(t, i + 1, Len(t))
Remove(t, a, b) == SubSeq(t, 1, a) \o SubSeq(t, b + 1, Len(t))

RECURSIVE Repeat(_, _)
Repeat(c, n) == IF n = 0 THEN <<>> ELSE <<c>> \o Repeat(c, n - 1)

\* n copies of c typed together at the cursor.
InsertRun(t, i, c, n) == SubSeq(t, 1, i) \o Repeat(c, n) \o SubSeq(t, i + 1, Len(t))

\* fx draws the text and moves the cursor to its own count of the cells
\* before it.
Place(t, i) == text' = t /\ cursor' = i /\ col' = FxCol(t, i)

Init == text = <<>> /\ cursor = 0 /\ col = 0

TypeStep(c) == Place(Insert(text, cursor, c), cursor + 1)
TypeRunStep(c, n) == Place(InsertRun(text, cursor, c, n), cursor + n)
Type(c) == Len(text) < MaxLen /\ TypeStep(c)
Left == Place(text, PrevStart(text, cursor))
Right == Place(text, NextEnd(text, cursor))
Backspace == Place(Remove(text, PrevStart(text, cursor), cursor), PrevStart(text, cursor))
Home == Place(text, 0)
End == Place(text, Len(text))
Clear == Place(<<>>, 0)

Next ==
    \/ \E c \in Classes : Type(c)
    \/ Left
    \/ Right
    \/ Backspace
    \/ Home
    \/ End
    \/ Clear

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ text \in Seq(Classes)
    /\ Len(text) <= MaxLen
    /\ cursor \in 0..Len(text)
    /\ col \in Nat

\* The cursor fx draws sits where the terminal drew the text before it.
CursorAligned == col = TermCol(text, cursor)

\* The row ends where fx thinks it does, so text drawn after it, a repaint,
\* and a wrap land on the terminal's columns.
RowAligned == FxCol(text, Len(text)) = TermCol(text, Len(text))

\* Moving the cursor never stops between a character and a mark the
\* terminal drew on it.
StopsAtCells == \A s \in Stops(text) : s = 0 \/ s = Len(text) \/ TermWidth(text, s + 1) > 0

\* The terminal shows what it should: every mark whose base is drawn, the last
\* column included, as many as the cell has room for, a mark with no base on a
\* circle of its own and never on the prompt's cell, and none on a row that
\* has no content cells.
MarksShown == Shown(text).seq = Wanted(text)

\* The step never fails: a cell that has no room for a mark drops it, and fx
\* goes on.
Alive == ~Shown(text).fail

\* No cell holds more than Cap bytes of text.
CellWithinCap == ~Shown(text).over

\* Witness: a base with two stacked marks, the cursor right after them, and
\* more text to their right. The passing config reaches this state.
NoStackedCluster ==
    ~(\E i \in 1..(Len(text) - 3) :
        /\ text[i] = "base"
        /\ text[i + 1] = "mark"
        /\ text[i + 2] = "mark"
        /\ cursor = i + 2)

\* Witness: the limit drops a mark. The passing config reaches this state, so
\* its check of the limit is not vacuous.
NoCapDrop == Shown(text).dropped = 0

\* Witness: a mark with no base is drawn on its circle, with text after it and
\* the cursor at the end.
NoBareCircle ==
    ~(/\ Len(text) >= 2
      /\ BareAt(text, 1)
      /\ cursor = Len(text)
      /\ Len(Shown(text).seq) > 0
      /\ Shown(text).seq[1] = "circle")
=============================================================================
