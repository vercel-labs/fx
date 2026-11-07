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
(* The composer wraps its text into rows of Cols cells. Two steps decide   *)
(* whether the marks on a character whose cell ends at the right margin    *)
(* reach the screen: the row builder must keep them on the full row        *)
(* (src/ui/footer/input_presentation.zig appendLayoutUnit), and, because   *)
(* fx paints with autowrap off, the painter must turn autowrap on while it *)
(* writes them, or the terminal puts them on another cell                  *)
(* (src/core/terminal/engine.zig diffBand). Margin picks the behavior:     *)
(*   "fixed"            the change: both steps, for one-cell and two-cell *)
(*                      characters                                         *)
(*   "row-drops"        fx before it: the row builder dropped every        *)
(*                      zero-width unit after a full row, so the marks on  *)
(*                      any character in the last column vanished          *)
(*   "wide-only-guard"  planted bug: the row keeps the marks but only      *)
(*                      two-cell characters get the painter's guard        *)
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
\* zero-width unit stays on its base's row. A zero-width unit is lost from
\* its base when that base ends at the right margin and one of the two steps
\* above fails for it. `used` counts the cells of the current row, and `base`
\* is the width of the last unit with cells on it (0 before any).
LostAtMargin(w) ==
    \/ Margin = "row-drops"
    \/ Margin = "wide-only-guard" /\ w # 2

RECURSIVE ShownFrom(_, _, _, _)
ShownFrom(t, i, used, base) ==
    IF i > Len(t) THEN <<>>
    ELSE IF FxWidth(t[i]) = 0
    THEN (IF base > 0 /\ used = Cols /\ LostAtMargin(base) THEN <<>> ELSE <<t[i]>>)
         \o ShownFrom(t, i + 1, used, base)
    ELSE LET start == IF used + FxWidth(t[i]) > Cols THEN 0 ELSE used
         IN <<t[i]>> \o ShownFrom(t, i + 1, start + FxWidth(t[i]), FxWidth(t[i]))

Shown(t) == ShownFrom(t, 1, 0, 0)

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

\* The terminal shows every mark the text holds, the last column included.
MarksShown == Shown(text) = text

\* Witness: a base with two stacked marks, the cursor right after them, and
\* more text to their right. The passing config reaches this state.
NoStackedCluster ==
    ~(\E i \in 1..(Len(text) - 3) :
        /\ text[i] = "base"
        /\ text[i + 1] = "mark"
        /\ text[i + 2] = "mark"
        /\ cursor = i + 2)
=============================================================================
