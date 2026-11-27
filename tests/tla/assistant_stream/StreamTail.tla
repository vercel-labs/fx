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
\* Unpaced variants (original StreamTail model, 1 token per Receive, immediate reveal):
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
\* Paced and language-gated variants (worker queues 1 presentation step per token in Q;
\* UI reveals k steps per Reveal, applying only the k-th step's tail; Boundary and Finish
\* wait until Q is empty; language gate stages text in the tail only until Accept or Reject):
\*   "design_paced"               new design: smooth reveal within window W, gate preview, safe finish/boundary.
\*   "current_paced"              today's unpaced reveal: Reveal drains all of Q at once (breaks SmoothReveal).
\*   "current_gate"               today's gate: shows nothing while staging, then reveals all at once on Accept (breaks SmoothReveal).
\*   "mutant_finish_ignores_tail" Finish allowed while Q holds tail-only steps (breaks NoLossAtFinish).
\*   "mutant_boundary_flush"      Boundary flushes Q at once without waiting (breaks BoundaryAfterQueue).
\*   "mutant_reject_commits"      GateReject commits staged text instead of clearing it (breaks NoRejectedCommit).
\*   "mutant_no_age_cap"          Reveal ignores the age >= W - 1 cap (breaks BoundedStall).
\*
\* ScrollLag 0: the terminal scrolls as soon as rows overflow. 1: one row later.
\* ChunkMax: maximum tokens per received chunk. W: reveal smoothing window in frames.
EXTENDS Naturals, Sequences

CONSTANTS MaxLen, Variant, ScreenRows, ScrollLag, ChunkMax, W

VARIABLES
    fullSrc,           \* the whole token sequence, chosen at Init
    src,               \* the tokens received so far
    committed,         \* finished rows, append only
    tail,              \* rows below committed
    history,           \* rows moved into terminal scrollback
    spec,              \* design_b only: a word after an open mark is written as bold
    Q,                 \* FIFO queue of presentation steps awaiting reveal
    shown,             \* revealed screen record: [rows |-> ..., len |-> ...]
    stalled,           \* Reveal actions since the oldest queued step arrived
    gate,              \* language gate state: "none", "staging", "accepted", "rejected"
    finished,          \* flag: TRUE once Finish has committed the reply
    cancelled,         \* flag: TRUE once Cancel has stopped the turn
    stagedIds,         \* token indices received while gate = "staging"
    lastRevealCount,   \* steps shown by the immediately preceding Reveal (or flush)
    lastRevealQueue,   \* Len(Q) before that Reveal (or flush)
    lastRevealExpired, \* queued steps with age >= W - 1 before that Reveal
    lastBoundaryQueue, \* Len(Q) when Boundary ran (must be 0)
    lastBoundaryLen    \* Len(src) at the last Boundary, to avoid redundant boundary stutters

vars == << fullSrc, src, committed, tail, history, spec, Q, shown, stalled, gate,
           finished, cancelled, stagedIds, lastRevealCount, lastRevealQueue,
           lastRevealExpired, lastBoundaryQueue, lastBoundaryLen >>

Toks == {"w", "o", "c", "nl", "u"}

PacedVariants == {
    "current_paced",
    "current_gate",
    "design_paced",
    "mutant_finish_ignores_tail",
    "mutant_boundary_flush",
    "mutant_reject_commits",
    "mutant_no_age_cap"
}
IsPaced(V) == V \in PacedVariants

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b
CeilDiv(a, b) == (a + b - 1) \div b
PaceCap(q) == Max(1, CeilDiv(q, W))

\* Number of oldest queued steps whose age has reached W - 1 (must drain on this Reveal).
RECURSIVE ExpiredPrefixLen(_, _)
ExpiredPrefixLen(q, w) ==
    IF q = <<>> THEN 0
    ELSE IF Head(q).age >= w - 1
    THEN 1 + ExpiredPrefixLen(Tail(q), w)
    ELSE 0

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

\* mutant_never_commit and staging tail: every row is shown in the tail, final or not,
\* except an underline line or the empty open line.
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

\* Presentation of prefix s under end-flag e and gate state g.
Presentation(s, e, g, V) ==
    IF s = <<>> THEN <<>>
    ELSE IF g = "staging" THEN CollectAllTail(Info(s, FALSE, V))
    ELSE Rendered(s, e, V) \o Held(s, e, V)

\* Worker presentation step for token prefix s.
StepFor(s, g, V) ==
    [committed |-> IF g = "staging" THEN <<>> ELSE Rendered(s, FALSE, V),
     tail      |-> IF g = "staging" THEN CollectAllTail(Info(s, FALSE, V)) ELSE Held(s, FALSE, V),
     len       |-> Len(s),
     age       |-> 0]

Screen == IF IsPaced(Variant) THEN shown.rows ELSE committed \o tail

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
    /\ Q = <<>>
    /\ shown = [rows |-> <<>>, len |-> 0]
    /\ stalled = 0
    /\ gate \in (IF ~IsPaced(Variant) THEN {"none"}
                 ELSE IF Variant \in {"current_gate", "mutant_reject_commits"} THEN {"staging"}
                 ELSE IF Variant = "mutant_no_age_cap" THEN {"none"}
                 ELSE {"none", "staging"})
    /\ finished = FALSE
    /\ cancelled = FALSE
    /\ stagedIds = {}
    /\ lastRevealCount = 0
    /\ lastRevealQueue = 0
    /\ lastRevealExpired = 0
    /\ lastBoundaryQueue = 0
    /\ lastBoundaryLen = 0

\* Unpaced Receive (original StreamTail variants).
ReceiveUnpaced ==
    /\ Len(src) < Len(fullSrc)
    /\ LET tok == fullSrc[Len(src) + 1]
           s2 == Append(src, tok)
           e2 == Len(s2) = Len(fullSrc)
           step == DBStep(committed, src, tok, spec)
           rows == Rendered(s2, e2, Variant)
           comm2 == IF Variant = "design_b"
                    THEN step.c
                    ELSE IF Variant = "mutant_never_commit"
                    THEN committed
                    ELSE committed \o SubSeq(rows, Len(committed) + 1, Len(rows))
           tail2 == Held(s2, e2, Variant)
       IN /\ src' = s2
          /\ committed' = comm2
          /\ tail' = tail2
          /\ shown' = [rows |-> comm2 \o tail2, len |-> Len(s2)]
          /\ spec' = IF Variant = "design_b" THEN step.sp ELSE FALSE
    /\ UNCHANGED << fullSrc, history, Q, stalled, gate, finished, cancelled, stagedIds,
                  lastRevealCount, lastRevealQueue, lastRevealExpired, lastBoundaryQueue, lastBoundaryLen >>

\* Paced Receive: one chunk of 1..ChunkMax tokens arrives; worker produces 1 step per token.
ReceivePaced ==
    /\ ~finished /\ ~cancelled /\ gate /= "rejected"
    /\ Len(src) < Len(fullSrc)
    /\ \E c \in 1..Min(ChunkMax, Len(fullSrc) - Len(src)) :
        LET s2 == SubSeq(fullSrc, 1, Len(src) + c)
        IN /\ src' = s2
           /\ stagedIds' = IF gate = "staging"
                           THEN stagedIds \cup ((Len(src) + 1)..Len(s2))
                           ELSE stagedIds
           /\ IF Variant = "current_gate" /\ gate = "staging"
              THEN /\ Q' = Q
                   /\ UNCHANGED << lastRevealCount, lastRevealQueue, lastRevealExpired, lastBoundaryQueue >>
              ELSE /\ Q' = Q \o [j \in 1..c |-> StepFor(SubSeq(fullSrc, 1, Len(src) + j), gate, Variant)]
                   /\ lastRevealCount' = 0
                   /\ lastRevealQueue' = 0
                   /\ lastRevealExpired' = 0
                   /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, committed, tail, history, spec, shown, stalled, gate,
                  finished, cancelled, lastBoundaryLen >>

Receive == IF IsPaced(Variant) THEN ReceivePaced ELSE ReceiveUnpaced

\* UI reveals the oldest k steps from Q, applying only the k-th step's tail.
\* Requiring k >= ceil(Len(Q) / W) matches the implementation's window_steps floor;
\* requiring k >= ExpiredPrefixLen(Q, W) (steps with age >= W - 1) enforces the
\* drain-window age cap so shrinking ceil(Len(Q)/W) cannot leave a slot stalled > W.
Reveal ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled /\ gate /= "rejected"
    /\ Q /= <<>>
    /\ LET expired == ExpiredPrefixLen(Q, W)
           minK == IF Variant = "mutant_no_age_cap" THEN CeilDiv(Len(Q), W)
                   ELSE Max(CeilDiv(Len(Q), W), expired)
           maxK == IF Variant = "mutant_no_age_cap" THEN PaceCap(Len(Q))
                   ELSE Max(PaceCap(Len(Q)), expired)
       IN \E k \in (IF Variant = "current_paced" THEN {Len(Q)} ELSE minK..maxK) :
            LET chosen == Q[k]
                rem == [i \in 1..(Len(Q) - k) |-> [Q[k + i] EXCEPT !.age = @ + 1]]
            IN /\ committed' = chosen.committed
               /\ tail' = chosen.tail
               /\ shown' = [rows |-> chosen.committed \o chosen.tail, len |-> chosen.len]
               /\ Q' = rem
               /\ stalled' = IF rem = <<>> THEN 0 ELSE rem[1].age
               /\ lastRevealCount' = k
               /\ lastRevealQueue' = Len(Q)
               /\ lastRevealExpired' = IF Variant = "mutant_no_age_cap" THEN 0 ELSE expired
               /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, src, history, spec, gate, finished, cancelled, stagedIds, lastBoundaryLen >>

\* Block boundary (closed code block, table, or rule): must wait until Q is empty.
Boundary ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled
    /\ gate \in {"none", "accepted"}
    /\ Len(src) > 0
    /\ lastBoundaryLen < Len(src)
    /\ (Variant = "mutant_boundary_flush" \/ Q = <<>>)
    /\ IF Variant = "mutant_boundary_flush" /\ Q /= <<>>
       THEN LET last == Q[Len(Q)]
            IN /\ committed' = last.committed
               /\ tail' = last.tail
               /\ shown' = [rows |-> last.committed \o last.tail, len |-> last.len]
               /\ Q' = <<>>
               /\ stalled' = 0
               /\ lastRevealCount' = Len(Q)
               /\ lastRevealQueue' = Len(Q)
               /\ lastRevealExpired' = 0
               /\ lastBoundaryQueue' = Len(Q)
               /\ lastBoundaryLen' = Len(src)
       ELSE /\ lastRevealCount' = 0
            /\ lastRevealQueue' = 0
            /\ lastRevealExpired' = 0
            /\ lastBoundaryQueue' = 0
            /\ lastBoundaryLen' = Len(src)
            /\ UNCHANGED << committed, tail, shown, Q, stalled >>
    /\ UNCHANGED << fullSrc, src, history, spec, gate, finished, cancelled, stagedIds >>

\* Turn Finish / commit: must wait until Q is empty and gate is not staging/rejected.
Finish ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled
    /\ gate \in {"none", "accepted"}
    /\ Len(src) = Len(fullSrc)
    /\ IF Variant = "mutant_finish_ignores_tail"
       THEN (Q = <<>> \/ \A i \in 1..Len(Q) : Q[i].committed = committed)
       ELSE Q = <<>>
    /\ LET comm2 == IF Variant = "mutant_finish_ignores_tail" /\ Q /= <<>>
                    THEN IF shown.len = 0 THEN <<>>
                         ELSE Rendered(SubSeq(src, 1, shown.len), TRUE, Variant)
                    ELSE Rendered(src, TRUE, Variant)
           len2 == IF Variant = "mutant_finish_ignores_tail" /\ Q /= <<>>
                   THEN shown.len
                   ELSE Len(src)
       IN /\ committed' = comm2
          /\ tail' = <<>>
          /\ shown' = [rows |-> comm2, len |-> len2]
    /\ finished' = TRUE
    /\ lastRevealCount' = 0
    /\ lastRevealQueue' = 0
    /\ lastRevealExpired' = 0
    /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, src, history, spec, Q, stalled, gate, cancelled, stagedIds, lastBoundaryLen >>

\* Language gate accepts the staged candidate text.
GateAccept ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled
    /\ gate = "staging"
    /\ Len(src) > 0
    /\ gate' = "accepted"
    /\ IF Variant = "current_gate"
       THEN LET comm2 == Rendered(src, FALSE, Variant)
                tail2 == Held(src, FALSE, Variant)
            IN /\ committed' = comm2
               /\ tail' = tail2
               /\ shown' = [rows |-> comm2 \o tail2, len |-> Len(src)]
               /\ lastRevealCount' = Len(src)
               /\ lastRevealQueue' = Len(src)
               /\ lastRevealExpired' = 0
               /\ lastBoundaryQueue' = 0
               /\ UNCHANGED << Q >>
       ELSE LET comm2 == IF shown.len = 0 THEN <<>> ELSE Rendered(SubSeq(src, 1, shown.len), FALSE, Variant)
                tail2 == IF shown.len = 0 THEN <<>> ELSE Held(SubSeq(src, 1, shown.len), FALSE, Variant)
            IN /\ committed' = comm2
               /\ tail' = tail2
               /\ shown' = [rows |-> comm2 \o tail2, len |-> shown.len]
               /\ Q' = [i \in 1..Len(Q) |->
                        [StepFor(SubSeq(src, 1, Q[i].len), "accepted", Variant) EXCEPT !.age = Q[i].age]]
               /\ lastRevealCount' = 0
               /\ lastRevealQueue' = 0
               /\ lastRevealExpired' = 0
               /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, src, history, spec, stalled, finished, cancelled, stagedIds, lastBoundaryLen >>

\* Language gate rejects the staged candidate text: clears tail and commits nothing.
GateReject ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled
    /\ gate = "staging"
    /\ Len(src) > 0
    /\ gate' = "rejected"
    /\ IF Variant = "mutant_reject_commits"
       THEN LET comm2 == Rendered(src, TRUE, Variant)
            IN /\ committed' = comm2
               /\ tail' = <<>>
               /\ shown' = [rows |-> comm2, len |-> Len(src)]
       ELSE /\ committed' = <<>>
            /\ tail' = <<>>
            /\ shown' = [rows |-> <<>>, len |-> 0]
    /\ Q' = <<>>
    /\ stalled' = 0
    /\ lastRevealCount' = 0
    /\ lastRevealQueue' = 0
    /\ lastRevealExpired' = 0
    /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, src, history, spec, finished, cancelled, stagedIds, lastBoundaryLen >>

\* Cancel stops the turn fast at any active step.
Cancel ==
    /\ IsPaced(Variant)
    /\ ~finished /\ ~cancelled /\ gate /= "rejected"
    /\ cancelled' = TRUE
    /\ Q' = <<>>
    /\ stalled' = 0
    /\ IF gate = "staging"
       THEN /\ committed' = <<>>
            /\ tail' = <<>>
            /\ shown' = [rows |-> <<>>, len |-> 0]
       ELSE UNCHANGED << committed, tail, shown >>
    /\ lastRevealCount' = 0
    /\ lastRevealQueue' = 0
    /\ lastRevealExpired' = 0
    /\ lastBoundaryQueue' = 0
    /\ UNCHANGED << fullSrc, src, history, spec, gate, finished, stagedIds, lastBoundaryLen >>

\* The terminal moves a row into scrollback. Only committed rows may go there.
ScrollToHistory ==
    /\ Len(Screen) > ScreenRows + ScrollLag
    /\ history < (IF Variant = "mutant_tail_history" THEN Len(Screen) ELSE Len(committed))
    /\ history' = history + 1
    /\ UNCHANGED << fullSrc, src, committed, tail, spec, Q, shown, stalled, gate,
                  finished, cancelled, stagedIds, lastRevealCount, lastRevealQueue,
                  lastRevealExpired, lastBoundaryQueue, lastBoundaryLen >>

Done ==
    /\ IF IsPaced(Variant)
       THEN (finished \/ cancelled \/ gate = "rejected")
       ELSE Len(src) = Len(fullSrc)
    /\ UNCHANGED vars

Next ==
    IF IsPaced(Variant)
    THEN Receive \/ Reveal \/ Boundary \/ Finish \/ GateAccept \/ GateReject \/ Cancel \/ ScrollToHistory \/ Done
    ELSE Receive \/ ScrollToHistory \/ Done

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ \A i \in 1..Len(src) : src[i] \in Toks
    /\ history \in Nat
    /\ spec \in BOOLEAN
    /\ stalled \in Nat
    /\ gate \in {"none", "staging", "accepted", "rejected"}
    /\ finished \in BOOLEAN
    /\ cancelled \in BOOLEAN
    /\ shown.len \in 0..Len(src)
    /\ Len(Q) <= MaxLen
    /\ \A i \in 1..Len(Q) : Q[i].len \in 1..Len(src) /\ Q[i].age \in Nat
    /\ lastRevealCount \in Nat
    /\ lastRevealQueue \in Nat
    /\ lastRevealExpired \in Nat
    /\ lastBoundaryQueue \in Nat
    /\ lastBoundaryLen \in 0..Len(src)

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

\* 6. The revealed screen is always the presentation of a prefix of the received tokens, in order.
ShownIsPrefix ==
    /\ shown.len \in 0..Len(src)
    /\ shown.rows = Presentation(SubSeq(src, 1, shown.len), finished, gate, Variant)

\* 7. One Reveal shows at most max(1, ceil(Len(Q) / W)) steps, unless draining expired steps (age >= W - 1).
SmoothReveal ==
    lastRevealCount > 0 => lastRevealCount <= Max(PaceCap(lastRevealQueue), lastRevealExpired)

\* 8. While Q is non-empty, stalled <= W (the backlog clears within W reveals).
BoundedStall ==
    Q /= <<>> => stalled <= W

\* 9. When Finish happens, Q is empty and the screen shows every received token.
NoLossAtFinish ==
    finished => (Q = <<>> /\ shown.len = Len(src) /\ committed = Batch(src) /\ tail = <<>>)

\* 10. Boundary happens only when Q is empty.
BoundaryAfterQueue ==
    lastBoundaryQueue = 0

\* 11. No token received while staging ever reaches committed rows after GateReject.
NoRejectedCommit ==
    (gate = "rejected") =>
        \A l \in 1..Len(committed) : \A j \in 1..Len(committed[l]) :
            committed[l][j].n \notin stagedIds

=============================================================================
