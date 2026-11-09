------------------------- MODULE TranscriptScrollback -------------------------
(***************************************************************************)
(* Where the rows of a resumed session go between the terminal's screen    *)
(* and its scrollback (src/ui/transcript/runtime.zig). A resume publishes  *)
(* the saved transcript into native scrollback in bounded frames, until    *)
(* the screen holds the last rows of the published flow. Entries added     *)
(* while it publishes, such as the turn of a prompt submitted in the       *)
(* meantime, stay hidden behind the published flow. The publication then   *)
(* hands over to the live flow, which includes them, and the transcript    *)
(* anchor is thrown away. Every frame after that scrolls the rows that     *)
(* leave the top of the screen into scrollback.                            *)
(*                                                                         *)
(* A row is a visual row of the flow, numbered from 0. The screen shows    *)
(* rows [view, view + area). Scrollback holds the rows a frame scrolled    *)
(* off the top, kept as ranges that merge when they touch. A frame that    *)
(* moves the top from view to newTop must scroll exactly the rows in       *)
(* between: fewer loses them, more shows them twice. After every frame the *)
(* runtime sets its history mark to the new top, which claims that every   *)
(* row above it is in scrollback.                                          *)
(*                                                                         *)
(* Rule picks what the frame after the handoff scrolls:                    *)
(*   fixed       the handoff mark: it remembers the old top and scrolls    *)
(*               what the new top passes, then clears itself                *)
(*   today       the frame scrolls nothing, as origin/main does            *)
(*   overscroll  one row more than the new top passes                      *)
(*   undercount  one row fewer                                             *)
(*   mark_ahead  claims one more row than it scrolled                      *)
(*   keep_mark   leaves the mark armed, so a later frame scrolls it again  *)
(*                                                                         *)
(* Not modeled: a resize (a new width or terminal height) at the handoff,  *)
(* or the full transcript screen (Ctrl+O) open there. Both clear the mark  *)
(* and keep the path of origin/main; tests/e2e/tui-resume.test.ts runs     *)
(* them in tmux. The frames that a taller composer defers during           *)
(* publication scroll nothing and do not move the mark, so they are not    *)
(* steps here. The first frame after the handoff does not see the          *)
(* composer get smaller: the model leaves that case to the stable rules.   *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    PublishedRows,  \* rows of the flow the resume publishes
    MaxArea,        \* the tallest transcript area
    MaxGrowth,      \* the most rows one submit adds
    MaxSubmits,     \* how many submits a behavior has
    MaxStep,        \* the most rows one publication frame scrolls
    Rule

Rules == {"fixed", "today", "overscroll", "undercount", "mark_ahead", "keep_mark"}

ASSUME /\ PublishedRows \in Nat /\ MaxArea \in 1..(PublishedRows - 1)
       /\ MaxGrowth \in Nat \ {0} /\ MaxSubmits \in Nat /\ MaxStep \in Nat \ {0}
       /\ Rule \in Rules

VARIABLES
    phase,    \* "publishing", "handoff" (anchor thrown away), or "live"
    total,    \* rows of the live flow, which grows with every submit
    view,     \* the row at the top of the screen
    area,     \* rows of the transcript area
    sb,       \* scrollback: ranges of rows that a frame scrolled off the top
    mark,     \* the runtime's history mark: rows [0, mark) are claimed to be in scrollback
    armed,    \* the handoff mark: set at the handoff, used by one frame
    submits

vars == <<phase, total, view, area, sb, mark, armed, submits>>

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

HistEnd == IF sb = <<>> THEN 0 ELSE sb[Len(sb)].hi

\* Rows [lo, lo + n) enter scrollback, joining the range before them if they touch it.
AddRange(lo, n) ==
    IF n = 0 THEN sb
    ELSE IF Len(sb) > 0 /\ sb[Len(sb)].hi = lo
         THEN [sb EXCEPT ![Len(sb)].hi = lo + n]
         ELSE Append(sb, [lo |-> lo, hi |-> lo + n])

Init ==
    /\ phase = "publishing"
    /\ total = PublishedRows
    /\ view = 0
    /\ area \in 1..MaxArea
    /\ sb = <<>>
    /\ mark = 0
    /\ armed = FALSE
    /\ submits = 0

\* A publication frame scrolls the top of the staged window into scrollback.
Publish ==
    /\ phase = "publishing"
    /\ view < PublishedRows - area
    /\ \E s \in 1..Min(MaxStep, PublishedRows - area - view) :
        /\ sb' = AddRange(view, s)
        /\ view' = view + s
        /\ mark' = view + s
    /\ UNCHANGED <<phase, total, area, armed, submits>>

\* The last publication frame committed: the live flow takes over and the
\* transcript anchor is thrown away. The handoff mark remembers the screen.
Handoff ==
    /\ phase = "publishing"
    /\ view = PublishedRows - area
    /\ phase' = "handoff"
    /\ armed' = TRUE
    /\ UNCHANGED <<total, view, area, sb, mark, submits>>

\* The user submits a prompt. During publication its rows stay hidden.
Submit ==
    /\ submits < MaxSubmits
    /\ \E g \in 1..MaxGrowth : total' = total + g
    /\ submits' = submits + 1
    /\ UNCHANGED <<phase, view, area, sb, mark, armed>>

LiveScroll(newTop) == Max(0, newTop - view)

HandoffScroll(newTop) ==
    CASE Rule = "today"      -> 0
      [] Rule = "overscroll" -> LiveScroll(newTop) + 1
      [] Rule = "undercount" -> Max(0, LiveScroll(newTop) - 1)
      [] OTHER               -> LiveScroll(newTop)

Scrolled(newTop) ==
    IF phase = "handoff" THEN HandoffScroll(newTop)
    ELSE IF Rule = "keep_mark" /\ armed THEN LiveScroll(newTop) + (total - PublishedRows)
    ELSE LiveScroll(newTop)

\* A frame of the live flow, with the composer at any height. A live frame
\* never moves the top above the history mark.
Frame ==
    /\ phase \in {"handoff", "live"}
    /\ \E newArea \in 1..MaxArea :
        /\ phase = "handoff" => newArea <= area
        /\ LET newTop == Max(total - newArea, IF phase = "live" THEN mark ELSE 0)
               s == Scrolled(newTop)
           IN /\ sb' = AddRange(view, s)
              /\ view' = newTop
              /\ mark' = IF Rule = "mark_ahead" THEN newTop + 1 ELSE newTop
        /\ area' = newArea
    /\ phase' = "live"
    /\ armed' = (Rule = "keep_mark")
    /\ UNCHANGED <<total, submits>>

Next == Publish \/ Handoff \/ Submit \/ Frame

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"publishing", "handoff", "live"}
    /\ total \in Nat /\ view \in Nat /\ area \in 1..MaxArea /\ mark \in Nat
    /\ armed \in BOOLEAN /\ submits \in 0..MaxSubmits
    /\ \A i \in 1..Len(sb) : sb[i].lo \in Nat /\ sb[i].hi \in Nat /\ sb[i].lo < sb[i].hi

\* Scrollback holds each row once and in order: one range, from row 0.
InOrderOnce == Len(sb) <= 1 /\ (Len(sb) = 1 => sb[1].lo = 0)

\* No row above the top of the screen is missing from scrollback.
NothingAbove == HistEnd >= view

\* No row is in scrollback and on the screen at once.
NothingBoth == HistEnd <= view

\* The history mark never counts a row that is not in scrollback.
MarkHonest == mark <= HistEnd
=============================================================================
