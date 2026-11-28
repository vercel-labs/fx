---------------------------- MODULE StreamTail ----------------------------
\* Abstract model of how fx shows a streamed markdown reply while it arrives.
\* Design record only; no product code. RULES.md R7.2 asks for this model.
\*
\* Tokens: "w" word, "o" open emphasis mark, "c" close emphasis mark, "nl" end
\* of line, "u" setext underline line (alone on its line, between two "nl").
\* Input domain (WellFormed): emphasis and setext headings only. Excluded: a line of only "o"/"c",
\* a "u" line with no word above it, and an "o" directly before a "c".
\* Why: CommonMark renders those as a thematic break, as text, or as an empty pair, which Batch does not model.
\*
\* Requirement NoUnfinalMark: never show a mark that is not final. A mark is identified by
\* its source token: every mark cell on screen is a mark of the final output on the same
\* row, with the same token.
\*
\* Variant selects the design:
\*   "current"              today: held text is not shown, the tail is empty.
\*   "design_a"             held text is shown in the tail. A line whose nl has come shows
\*                          its final cells, as it will commit. The open line is repaired:
\*                          an "o" opens bold. Rule A: an open line whose tokens are only "o"
\*                          and "c" shows nothing, as fx's block-marker hide does. Rule B: a
\*                          run of adjacent "c" with no open "o" before it shows as marks once
\*                          a token other than "c" follows the run on the line; the run that
\*                          ends the open text shows nothing.
\*   "design_b"             no tail: each word is written at once, speculatively.
\*   "mutant_no_repair"     design_a, but the open line shows an unclosed "o" as a mark cell.
\*   "mutant_tail_history"  design_a, but scrolling may move tail rows to history.
\*   "mutant_commit_early"  design_a, but a line commits at its nl, before a "u"
\*                          after it can be seen.
\*   "mutant_never_commit"  design_a, but committed never grows and the tail shows every row.
\*   "mutant_drop_waiting"  design_a, but the tail shows only the open line, not a line
\*                          that waits for a possible "u".
\*
\* ScrollLag 0: the terminal scrolls as soon as rows overflow. 1: one row later.
EXTENDS Naturals, Sequences

CONSTANTS MaxLen, Variant, ScreenRows, ScrollLag

VARIABLES
    fullSrc,    \* the whole token sequence, chosen at Init
    src,        \* the tokens received so far
    committed,  \* finished rows, append only
    tail,       \* rows below committed, replaced on every Receive
    history,    \* rows moved into terminal scrollback
    spec        \* design_b only: a word after an open mark is written as bold

vars == << fullSrc, src, committed, tail, history, spec >>

Toks == {"w", "o", "c", "nl", "u"}

\* A line of only "o" and "c" tokens, from a line start to the next nl or the end.
MarkOnlyLine(s) ==
    \E i \in 1..Len(s) :
        /\ s[i] \in {"o", "c"}
        /\ (i = 1 \/ s[i - 1] = "nl")
        /\ \A j \in i..Len(s) : (\A k \in i..j : s[k] /= "nl") => s[j] \in {"o", "c"}

\* A "u" sits alone on its line, directly after an "nl" and directly before one, and the
\* line above it has a word. No "o" is directly followed by "c". No line is only marks.
WellFormed(s) ==
    /\ \A i \in 1..Len(s) :
        s[i] = "u" => (i > 1 /\ s[i - 1] = "nl" /\ i < Len(s) /\ s[i + 1] = "nl")
    /\ \A i \in 1..Len(s) :
        s[i] = "u" => (\E k \in 1..(i - 2) : s[k] = "w" /\ (\A m \in k..(i - 2) : s[m] /= "nl"))
    /\ \A i \in 1..(Len(s) - 1) : ~(s[i] = "o" /\ s[i + 1] = "c")
    /\ ~MarkOnlyLine(s)

Sources == { s \in UNION { [1..n -> Toks] : n \in 1..MaxLen } : WellFormed(s) }

\* Every token keeps its position in fullSrc: the word index n.
Tokens(s) == [i \in 1..Len(s) |-> [n |-> i, tok |-> s[i]]]

\* Split a token sequence into lines. The last line is the open one; an "nl"
\* ends a line and is not part of any line.
RECURSIVE LinesOf(_)
LinesOf(ts) ==
    IF ts = <<>> THEN <<<<>>>>
    ELSE LET rest == LinesOf(Tail(ts))
         IN IF Head(ts).tok = "nl"
            THEN <<<<>>>> \o rest
            ELSE <<<<Head(ts)>> \o rest[1]>> \o Tail(rest)

Lines(s) == LinesOf(Tokens(s))

IsUOnly(line) == Len(line) = 1 /\ line[1].tok = "u"

\* Rule A: a line of tokens that are all "o" or "c" (and at least one).
MarksOnly(line) == Len(line) > 0 /\ \A j \in 1..Len(line) : line[j].tok \in {"o", "c"}

\* Line i is a setext heading when the line after it is a "u" line that has ended (its
\* nl has come). Until then fx shows the line as text, and so does the tail.
HeadingAt(i, L) == i + 1 < Len(L) /\ IsUOnly(L[i + 1])

HasClose(ts) == \E j \in 1..Len(ts) : ts[j].tok = "c"

WordKind(heading, bold) == IF heading THEN "heading" ELSE IF bold THEN "bold" ELSE "plain"

\* Cells of one line, by mode:
\*   "final"   the reference rule: a paired mark is hidden, an unpaired "o" or a
\*             lone "c" is a "mark" cell.
\*   "tail"    the repaired rule: an "o" opens bold to the end of the held text, and
\*             a run of "c" with no open "o" before it is a "mark" cell only when a
\*             token other than "c" follows it on the line (rule B).
\*   "mutant"  the final rule for "o", but the repaired rule for "c".
RECURSIVE Cells(_, _, _, _)
Cells(ts, bold, heading, mode) ==
    IF ts = <<>> THEN <<>>
    ELSE LET x == Head(ts)
             rest == Tail(ts)
         IN IF x.tok = "w"
            THEN << [k |-> WordKind(heading, bold), n |-> x.n] >> \o Cells(rest, bold, heading, mode)
            ELSE IF x.tok = "o" /\ mode = "tail"
            THEN Cells(rest, TRUE, heading, mode)
            ELSE IF x.tok = "o" /\ (bold \/ ~HasClose(rest))
            THEN << [k |-> "mark", n |-> x.n] >> \o Cells(rest, bold, heading, mode)
            ELSE IF x.tok = "o"
            THEN Cells(rest, TRUE, heading, mode)
            ELSE IF x.tok = "c" /\ mode /= "final" /\ ~bold /\ \E k \in 1..Len(rest) : rest[k].tok /= "c"
            THEN << [k |-> "mark", n |-> x.n] >> \o Cells(rest, FALSE, heading, mode)
            ELSE IF x.tok = "c" /\ (mode /= "final" \/ bold)
            THEN Cells(rest, FALSE, heading, mode)
            ELSE IF x.tok = "c"
            THEN << [k |-> "mark", n |-> x.n] >> \o Cells(rest, bold, heading, mode)
            ELSE Cells(rest, bold, heading, mode)

\* Line i is final when the line after it has ended (its nl has come), or the stream
\* ended. fx holds a line until the next line is processed, and it processes a line
\* only once its nl has come. A blank line that has ended also settles the line before
\* it, so it needs no case of its own. A heading line is final when its "u" line ended.
\* mutant_commit_early drops the wait: a line commits at its own nl.
Final(i, L, e, V) ==
    IF V = "mutant_commit_early"
    THEN (i < Len(L) \/ e)
    ELSE (e \/ (i + 1 < Len(L)))

\* Per line: whether it is final, whether its nl has come (it is not the open line),
\* whether it renders nothing (a "u" line, or the empty open line after a final nl),
\* and its cells in each mode.
Info(s, e, V) ==
    LET L == Lines(s)
        m == Len(L)
    IN [i \in 1..m |->
            [final  |-> Final(i, L, e, V),
             ended  |-> i < m,
             skip   |-> IsUOnly(L[i]) \/ (i = m /\ Len(L[i]) = 0),
             fcells |-> Cells(L[i], FALSE, HeadingAt(i, L), "final"),
             tcells |-> IF i = m /\ MarksOnly(L[i]) THEN <<>> ELSE Cells(L[i], FALSE, HeadingAt(i, L), "tail"),
             mcells |-> Cells(L[i], FALSE, HeadingAt(i, L), "mutant")]]

RECURSIVE CollectFinal(_), CollectHeld(_, _)
CollectFinal(inf) ==
    IF inf = <<>> THEN <<>>
    ELSE (IF inf[1].final /\ ~inf[1].skip THEN << inf[1].fcells >> ELSE <<>>)
         \o CollectFinal(Tail(inf))

\* A held line whose nl has come shows its final cells. Only the open line shows
\* repaired cells, or, in mutant_no_repair, its unclosed marks.
CollectHeld(inf, V) ==
    IF inf = <<>> THEN <<>>
    ELSE (IF ~inf[1].final /\ ~inf[1].skip
          THEN << IF inf[1].ended THEN inf[1].fcells
                  ELSE IF V = "mutant_no_repair" THEN inf[1].mcells
                  ELSE inf[1].tcells >>
          ELSE <<>>)
         \o CollectHeld(Tail(inf), V)

\* Rows that are final, in order: what committed should hold.
Rendered(s, e, V) == CollectFinal(Info(s, e, V))

\* mutant_never_commit: every row is shown in the tail, final or not, except an underline
\* line or the empty open line.
RECURSIVE CollectAllTail(_)
CollectAllTail(inf) ==
    IF inf = <<>> THEN <<>>
    ELSE (IF inf[1].skip THEN <<>> ELSE << IF inf[1].ended THEN inf[1].fcells ELSE inf[1].tcells >>)
         \o CollectAllTail(Tail(inf))

\* mutant_drop_waiting: only the open line (the last one) can be shown in the tail.
OpenOnly(inf) ==
    IF inf = <<>> THEN <<>>
    ELSE LET last == inf[Len(inf)]
         IN IF last.final \/ last.skip THEN <<>> ELSE << last.tcells >>

\* Rows that are not final yet: what the tail shows.
Held(s, e, V) ==
    IF V = "current" \/ V = "design_b" THEN <<>>
    ELSE IF V = "mutant_never_commit" THEN CollectAllTail(Info(s, e, V))
    ELSE IF V = "mutant_drop_waiting" THEN OpenOnly(Info(s, e, V))
    ELSE CollectHeld(Info(s, e, V), V)

\* Reference rendering of a finished sequence.
Batch(s) == Rendered(s, TRUE, "design_a")

Screen == committed \o tail

\* Word indexes on screen. A word is any cell that is not a "mark".
ScreenWords(scr) ==
    UNION { { scr[l][j].n : j \in { jj \in 1..Len(scr[l]) : scr[l][jj].k /= "mark" } }
            : l \in 1..Len(scr) }

IsPrefix(a, b) == Len(a) <= Len(b) /\ \A j \in 1..Len(a) : a[j] = b[j]

\* design_b: the token is written at once. A line break is written when the
\* next token arrives, so a trailing nl adds no empty row. The rest is guessed.
DBStep(c, src0, tok, sp) ==
    LET atLineStart == (src0 = <<>> \/ src0[Len(src0)] = "nl")
        base == IF atLineStart THEN Append(c, <<>>) ELSE c
        last == Len(base)
        n == Len(src0) + 1
    IN IF tok = "w"
       THEN [c |-> [base EXCEPT ![last] = Append(base[last], [k |-> IF sp THEN "bold" ELSE "plain", n |-> n])], sp |-> sp]
       ELSE IF tok = "o"
       THEN [c |-> base, sp |-> TRUE]
       ELSE IF tok = "c" /\ sp
       THEN [c |-> base, sp |-> FALSE]
       ELSE IF tok = "c"
       THEN [c |-> [base EXCEPT ![last] = Append(base[last], [k |-> "mark", n |-> n])], sp |-> FALSE]
       ELSE IF tok = "nl"
       THEN [c |-> base, sp |-> FALSE]
       ELSE [c |-> base, sp |-> sp]

Init ==
    /\ fullSrc \in Sources
    /\ src = <<>>
    /\ committed = <<>>
    /\ tail = <<>>
    /\ history = 0
    /\ spec = FALSE

Receive ==
    /\ Len(src) < Len(fullSrc)
    /\ LET tok == fullSrc[Len(src) + 1]
           s2 == Append(src, tok)
           e2 == Len(s2) = Len(fullSrc)
           step == DBStep(committed, src, tok, spec)
           rows == Rendered(s2, e2, Variant)
       IN /\ src' = s2
          /\ committed' = IF Variant = "design_b"
                          THEN step.c
                          ELSE IF Variant = "mutant_never_commit"
                          THEN committed
                          ELSE committed \o SubSeq(rows, Len(committed) + 1, Len(rows))
          /\ tail' = Held(s2, e2, Variant)
          /\ spec' = IF Variant = "design_b" THEN step.sp ELSE FALSE
    /\ UNCHANGED << fullSrc, history >>

\* The terminal moves a row into scrollback. Only committed rows may go there.
ScrollToHistory ==
    /\ Len(Screen) > ScreenRows + ScrollLag
    /\ history < (IF Variant = "mutant_tail_history" THEN Len(Screen) ELSE Len(committed))
    /\ history' = history + 1
    /\ UNCHANGED << fullSrc, src, committed, tail, spec >>

Done ==
    /\ Len(src) = Len(fullSrc)
    /\ UNCHANGED vars

Next == Receive \/ ScrollToHistory \/ Done

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ \A i \in 1..Len(src) : src[i] \in Toks
    /\ history \in Nat
    /\ spec \in BOOLEAN

\* 1. Committed rows are never different from the rows the final output has.
CommittedIsPrefixOfFinal ==
    LET finalRows == Batch(fullSrc)
    IN /\ Len(committed) <= Len(finalRows)
       /\ \A i \in 1..Len(committed) : IsPrefix(committed[i], finalRows[i])

\* 2. Once the whole sequence is in and nothing is held, committed is the final output.
FinalEqualsBatch ==
    (Len(src) = Len(fullSrc) /\ tail = <<>>) => committed = Batch(fullSrc)

\* 2b. At the end of the stream nothing is held, and committed is the final output.
\* Unlike FinalEqualsBatch, it still checks the output when the tail is not empty.
EndCommitsAll == Len(src) = Len(fullSrc) => (tail = <<>> /\ committed = Batch(fullSrc))

\* 3. Only committed rows can be in scrollback.
HistoryOnlyCommitted == history <= Len(committed)

\* 4. Never show a mark that is not final. A mark is identified by its source token (n),
\* not by its cell index: a final mark may stay hidden, so the index can differ.
NoUnfinalMark ==
    LET B == Batch(fullSrc)
    IN \A l \in 1..Len(Screen) : \A j \in 1..Len(Screen[l]) :
           Screen[l][j].k = "mark" => (l <= Len(B) /\ \E jj \in 1..Len(B[l]) : B[l][jj] = Screen[l][j])

\* 5. Every word is on screen in the step it arrives. A word is never on a "u"
\* line, so the clause "not inside a u line" holds for every word.
EveryWordVisible ==
    \A i \in 1..Len(src) : src[i] = "w" => i \in ScreenWords(Screen)

\* A word that is on screen stays on screen.
VisibleNeverShrinks ==
    [][ ScreenWords(committed \o tail) \subseteq ScreenWords(committed' \o tail') ]_vars

=============================================================================
