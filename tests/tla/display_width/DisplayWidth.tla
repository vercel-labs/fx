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
(*                                                                         *)
(* Rule picks fx's width and boundary rules:                               *)
(*   "fixed"          the change: Thai nonspacing marks measure 0 cells    *)
(*   "today"          fx before it: each Thai mark measures 1 cell         *)
(*   "sara-am"        planted bug: SARA AM measured as a mark, as a table  *)
(*                    that ran U+0E31-U+0E3A would                         *)
(*   "split-cluster"  planted bug: nextCharacterEnd stops after one unit   *)
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
(*   "bare-marks"       planted bug: only the early return sets the flag,  *)
(*                      so a row with no content cells still draws the     *)
(*                      marks that come before its first unit              *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS Rule, MaxLen, Cols, Margin

Classes == {"base", "mark", "am", "ascii", "wide", "latin_mark"}

\* The cells the terminal gives each class.
TermWidth(c) ==
    CASE c = "mark" -> 0
      [] c = "latin_mark" -> 0
      [] c = "wide" -> 2
      [] OTHER -> 1

\* The cells fx's runeWidth gives each class.
FxWidth(c) ==
    CASE c = "mark" -> IF Rule = "today" THEN 1 ELSE 0
      [] c = "am" -> IF Rule = "sara-am" THEN 0 ELSE 1
      [] OTHER -> TermWidth(c)

VARIABLES text, cursor, col
vars == <<text, cursor, col>>

\* The column after the first i units, as fx counts it and as the terminal
\* draws it. Columns count from the first cell after the composer's prefix.
RECURSIVE FxCol(_, _)
FxCol(t, i) == IF i = 0 THEN 0 ELSE FxCol(t, i - 1) + FxWidth(t[i])

RECURSIVE TermCol(_, _)
TermCol(t, i) == IF i = 0 THEN 0 ELSE TermCol(t, i - 1) + TermWidth(t[i])

\* nextCharacterEnd: one unit, then every unit fx measures as zero cells.
RECURSIVE SkipZero(_, _)
SkipZero(t, j) == IF j < Len(t) /\ FxWidth(t[j + 1]) = 0 THEN SkipZero(t, j + 1) ELSE j

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
\* unit with cells on it (0 before any).
LostAtMargin(w) ==
    \/ Margin = "row-drops"
    \/ Margin = "wide-only-guard" /\ w # 2

\* A unit of width w is drawn when a row has the cells for it.
Drawn(w) == w <= Cols

\* The flag when a row starts. A row with no content cells starts with it
\* set, so the marks of the units it cannot draw are dropped.
RowStartUndrawn == Cols = 0 /\ Margin \notin {"cell-less-keeps", "bare-marks"}

\* The flag after a unit with cells. In the "cell-less-keeps" bug the row
\* builder returns before it sets the flag on a row with no content cells.
AfterCells(undrawn, w) ==
    IF Cols = 0 /\ Margin = "cell-less-keeps" THEN undrawn ELSE ~Drawn(w)

RECURSIVE ShownFrom(_, _, _, _, _)
ShownFrom(t, i, used, base, undrawn) ==
    IF i > Len(t) THEN <<>>
    ELSE IF FxWidth(t[i]) = 0
    THEN (IF undrawn \/ (base > 0 /\ used = Cols /\ LostAtMargin(base)) THEN <<>> ELSE <<t[i]>>)
         \o ShownFrom(t, i + 1, used, base, undrawn)
    ELSE LET w == FxWidth(t[i])
             start == IF used + w > Cols THEN 0 ELSE used
         IN (IF Drawn(w) THEN <<t[i]>> ELSE <<>>)
            \o ShownFrom(t, i + 1, start + w, w, AfterCells(undrawn, w))

Shown(t) == ShownFrom(t, 1, 0, 0, RowStartUndrawn)

\* What the terminal must show of t: a unit with cells when a row has the
\* cells for it, a mark when its base is drawn, and a mark with no base only
\* on a row that has content cells. `ok` is whether the last unit with cells
\* is drawn.
RECURSIVE WantedFrom(_, _, _)
WantedFrom(t, i, ok) ==
    IF i > Len(t) THEN <<>>
    ELSE IF FxWidth(t[i]) = 0
    THEN (IF ok THEN <<t[i]>> ELSE <<>>) \o WantedFrom(t, i + 1, ok)
    ELSE (IF Drawn(FxWidth(t[i])) THEN <<t[i]>> ELSE <<>>)
         \o WantedFrom(t, i + 1, Drawn(FxWidth(t[i])))

Wanted(t) == WantedFrom(t, 1, Cols > 0)

Insert(t, i, c) == SubSeq(t, 1, i) \o <<c>> \o SubSeq(t, i + 1, Len(t))
Remove(t, a, b) == SubSeq(t, 1, a) \o SubSeq(t, b + 1, Len(t))

\* fx draws the text and moves the cursor to its own count of the cells
\* before it.
Place(t, i) == text' = t /\ cursor' = i /\ col' = FxCol(t, i)

Init == text = <<>> /\ cursor = 0 /\ col = 0

TypeStep(c) == Place(Insert(text, cursor, c), cursor + 1)
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
StopsAtCells == \A s \in Stops(text) : s = 0 \/ s = Len(text) \/ TermWidth(text[s + 1]) > 0

\* The terminal shows what it should: every mark whose base is drawn, the last
\* column included, and none on a row that has no content cells.
MarksShown == Shown(text) = Wanted(text)

\* Witness: a base with two stacked marks, the cursor right after them, and
\* more text to their right. The passing config reaches this state.
NoStackedCluster ==
    ~(\E i \in 1..(Len(text) - 3) :
        /\ text[i] = "base"
        /\ text[i + 1] = "mark"
        /\ text[i + 2] = "mark"
        /\ cursor = i + 2)
=============================================================================
