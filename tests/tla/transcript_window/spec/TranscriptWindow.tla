---- MODULE TranscriptWindow ----
\* The transcript window core: what the main screen holds, paints, reprints and
\* drops, and what Ctrl+O reads from the session log.
\*
\* Blocks are numbered by finish order (D5). Held blocks are the range
\* [heldFirst, nextSeq). A live session never drops its finished blocks: a
\* resize reprints the entire current session across compactions and turns.
\* Drops happen only when the session changes (/new, /clear, or clearing before
\* /resume), and drop only the departing session's blocks.
\*
\* design/DESIGN.md holds the decisions (D1-D11) and laws (L1-L22) this checks.
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    MaxSeq,      \* finished blocks over a run
    Ids,         \* live block ids
    MaxCycles,   \* compactions over a run
    Window,      \* blocks Ctrl+O holds
    Step,        \* blocks one log read asks for
    Slice,       \* blocks one reprint slice writes
    MaxTokens,   \* log reads over a run
    Saved,       \* TRUE for a saved session, FALSE for --no-save
    OnlyOlder    \* TRUE: the user only scrolls older and the log answers well (CtrlOReachesStart)

VARIABLES
    cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live, turnOpen,
    paintedThrough, reprinting,
    coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
    out, act,
    alive, cycleStarts,
    painted      \* blocks on the screen in this epoch, from the paint effects

core == <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live, turnOpen,
          paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart,
          pending, pendingDir, nextToken>>
vars == <<core, out, act, alive, cycleStarts, painted>>

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x
Range(s) == {s[i] : i \in DOMAIN s}
Effects == Range(out)

Init ==
    /\ cycle = 0 /\ cycleFirst = 0 /\ heldFirst = 0 /\ nextSeq = 0
    /\ savedThrough = 0 /\ live = {} /\ turnOpen = FALSE
    /\ paintedThrough = 0 /\ reprinting = FALSE
    /\ coOpen = FALSE /\ coLo = 0 /\ coHi = 0 /\ coAtStart = FALSE
    /\ pending = 0 /\ pendingDir = "older" /\ nextToken = 1
    /\ out = <<>> /\ act = [name |-> "Init"]
    /\ alive = TRUE /\ cycleStarts = {0}
    /\ painted = {}

\* Leaving or clearing the session (/new, /clear, or clearing before an
\* in-process /resume): drops all held blocks of the old session and starts
\* empty at 0.
SessionCleared ==
    /\ alive /\ ~OnlyOlder
    /\ act' = [name |-> "SessionCleared"]
    /\ out' = IF heldFirst < nextSeq
                 THEN <<[kind |-> "drop", from |-> heldFirst, to |-> nextSeq]>>
                 ELSE <<>>
    /\ cycle' = 0 /\ cycleFirst' = 0 /\ heldFirst' = 0 /\ nextSeq' = 0
    /\ savedThrough' = 0 /\ live' = {} /\ turnOpen' = FALSE
    /\ paintedThrough' = 0 /\ reprinting' = FALSE
    /\ coOpen' = FALSE /\ coLo' = 0 /\ coHi' = 0 /\ coAtStart' = FALSE
    /\ pending' = 0 /\ pendingDir' = "older" /\ nextToken' = 1
    /\ alive' = TRUE /\ cycleStarts' = {0}

-----------------------------------------------------------------------------
\* Events of the core.

TurnStarted ==
    /\ alive /\ ~turnOpen
    /\ turnOpen' = TRUE /\ out' = <<>> /\ act' = [name |-> "TurnStarted"]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pending, pendingDir, nextToken, alive, cycleStarts>>

TurnEnded ==
    /\ alive /\ turnOpen /\ live = {}     \* A4
    /\ turnOpen' = FALSE /\ out' = <<>> /\ act' = [name |-> "TurnEnded"]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pending, pendingDir, nextToken, alive, cycleStarts>>

\* Every open block can still finish within MaxSeq.
BlockOpened(id) ==
    /\ alive /\ turnOpen /\ id \notin live
    /\ nextSeq + Cardinality(live) < MaxSeq
    /\ live' = live \cup {id} /\ out' = <<>> /\ act' = [name |-> "BlockOpened", id |-> id]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, turnOpen,
                   paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pending, pendingDir, nextToken, alive, cycleStarts>>

BlockChanged(id) ==
    /\ alive /\ id \in live
    /\ out' = <<[kind |-> "repaint_block", id |-> id]>> /\ act' = [name |-> "BlockChanged", id |-> id]
    /\ UNCHANGED <<core, alive, cycleStarts>>

\* A block finishes after being live, or arrives already final (a prompt, a
\* notice). A final block leaves room for every live block to finish.
BlockFinished(id) ==
    /\ alive
    /\ IF id \in live THEN nextSeq < MaxSeq ELSE nextSeq + Cardinality(live) < MaxSeq
    /\ live' = live \ {id} /\ nextSeq' = nextSeq + 1 /\ act' = [name |-> "BlockFinished", id |-> id]
    /\ IF reprinting
          THEN /\ out' = <<>> /\ UNCHANGED paintedThrough
          ELSE /\ out' = <<[kind |-> "paint_final", seq |-> nextSeq]>>
               /\ paintedThrough' = nextSeq + 1
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, savedThrough, turnOpen,
                   reprinting, coOpen, coLo, coHi, coAtStart, pending,
                   pendingDir, nextToken, alive, cycleStarts>>

\* The log confirms every block below `through` (A3). Saves never drop held
\* blocks of the current session.
SavedThrough(through) ==
    /\ alive /\ Saved
    /\ through > savedThrough /\ through <= nextSeq
    /\ savedThrough' = Min(through, nextSeq) /\ out' = <<>>
    /\ act' = [name |-> "SavedThrough", through |-> through]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, live, turnOpen,
                   paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pending, pendingDir, nextToken, alive, cycleStarts>>

\* A compaction advances the cycle without dropping anything or moving
\* `heldFirst`, even between turns when the log already holds everything.
Compacted ==
    /\ alive /\ cycle < MaxCycles
    /\ cycle' = cycle + 1
    /\ cycleFirst' = nextSeq
    /\ cycleStarts' = cycleStarts \cup {nextSeq}
    /\ out' = <<>> /\ act' = [name |-> "Compacted"]
    /\ UNCHANGED <<heldFirst, nextSeq, savedThrough, live, turnOpen, paintedThrough,
                   reprinting, coOpen, coLo, coHi, coAtStart, pending,
                   pendingDir, nextToken, alive>>

Resized ==
    /\ alive
    /\ reprinting' = TRUE /\ paintedThrough' = heldFirst
    /\ out' = <<[kind |-> "reprint_begin"]>> /\ act' = [name |-> "Resized"]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, coOpen, coLo, coHi, coAtStart, pending, pendingDir,
                   nextToken, alive, cycleStarts>>

ReprintTick ==
    /\ alive /\ reprinting
    /\ act' = [name |-> "ReprintTick"]
    /\ IF paintedThrough >= nextSeq
          THEN /\ reprinting' = FALSE /\ out' = <<[kind |-> "repaint_live"]>>
               /\ UNCHANGED paintedThrough
          ELSE /\ out' = <<[kind |-> "reprint_slice", from |-> paintedThrough,
                            to |-> Min(paintedThrough + Slice, nextSeq)]>>
               /\ paintedThrough' = Min(paintedThrough + Slice, nextSeq)
               /\ UNCHANGED reprinting
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, coOpen, coLo, coHi, coAtStart, pending,
                   pendingDir, nextToken, alive, cycleStarts>>

CtrlOOpened ==
    /\ alive /\ ~coOpen
    /\ coOpen' = TRUE /\ coHi' = nextSeq
    /\ coLo' = Max(heldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0)
    /\ coAtStart' = (Max(heldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0) = 0)
    /\ pending' = 0
    /\ out' = <<[kind |-> "ctrlo_show",
                 lo |-> Max(heldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0),
                 hi |-> nextSeq]>>
    /\ act' = [name |-> "CtrlOOpened"]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, pendingDir, nextToken,
                   alive, cycleStarts>>

CtrlOScrolledOlder ==
    /\ alive /\ coOpen /\ pending = 0 /\ coLo > 0
    /\ act' = [name |-> "CtrlOScrolledOlder"]
    /\ IF coLo > heldFirst
          THEN /\ coLo' = coLo - 1
               /\ coHi' = Min(coHi, coLo - 1 + Window)
               /\ coAtStart' = (coLo - 1 = 0)
               /\ out' = <<[kind |-> "ctrlo_show", lo |-> coLo - 1, hi |-> Min(coHi, coLo - 1 + Window)]>>
               /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE IF Saved
               \* Out of tokens is a bound of the model, not a behavior: the
               \* action is then disabled rather than a silent no-op.
               THEN /\ nextToken <= MaxTokens
                    /\ pending' = nextToken /\ pendingDir' = "older"
                    /\ nextToken' = nextToken + 1
                    /\ out' = <<[kind |-> "read_log", token |-> nextToken, dir |-> "older",
                                 from |-> coLo, count |-> Step]>>
                    /\ UNCHANGED <<coLo, coHi, coAtStart>>
               ELSE /\ coAtStart' = TRUE
                    /\ out' = <<>>
                    /\ UNCHANGED <<coLo, coHi, pending, pendingDir, nextToken>>
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, alive, cycleStarts>>

CtrlOScrolledNewer ==
    /\ alive /\ coOpen /\ pending = 0 /\ coHi < nextSeq /\ ~OnlyOlder
    /\ act' = [name |-> "CtrlOScrolledNewer"]
    /\ IF coHi >= heldFirst
          THEN /\ coHi' = coHi + 1
               /\ coLo' = Max(coLo, coHi + 1 - Window)
               /\ coAtStart' = (Max(coLo, coHi + 1 - Window) = 0)
               /\ out' = <<[kind |-> "ctrlo_show", lo |-> Max(coLo, coHi + 1 - Window), hi |-> coHi + 1]>>
               /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE IF ~Saved
               \* No log: blocks before heldFirst are absent, jump to heldFirst.
               THEN /\ coLo' = heldFirst /\ coHi' = Min(heldFirst + 1, nextSeq)
                    /\ coAtStart' = (heldFirst = 0)
                    /\ out' = <<[kind |-> "ctrlo_show", lo |-> heldFirst, hi |-> Min(heldFirst + 1, nextSeq)]>>
                    /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE /\ nextToken <= MaxTokens
               /\ pending' = nextToken /\ pendingDir' = "newer"
               /\ nextToken' = nextToken + 1
               /\ out' = <<[kind |-> "read_log", token |-> nextToken, dir |-> "newer",
                            from |-> coHi, count |-> Step]>>
               /\ UNCHANGED <<coLo, coHi, coAtStart>>
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, alive, cycleStarts>>

CtrlOClosed ==
    /\ alive /\ coOpen /\ ~OnlyOlder
    /\ coOpen' = FALSE /\ pending' = 0 /\ out' = <<>> /\ act' = [name |-> "CtrlOClosed"]
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coLo, coHi, coAtStart,
                   pendingDir, nextToken, alive, cycleStarts>>

\* A reply for any token ever issued: the pending one, a stale one, or a
\* duplicate; `count` may be wrong (a garbage peer). The core clamps it.
Available(dir) == IF dir = "older" THEN coLo ELSE nextSeq - coHi
LogReadDone(token, count) ==
    /\ alive /\ token \in 1..(nextToken - 1) /\ count \in 0..(Step + 1)
    \* Under OnlyOlder the log answers the pending read with the true count.
    /\ OnlyOlder => (coOpen /\ token = pending /\ count = Min(Step, Available(pendingDir)))
    /\ act' = [name |-> "LogReadDone", token |-> token, count |-> count]
    /\ IF coOpen /\ pending = token
          THEN LET n == Min(Min(count, Step), Available(pendingDir))
                   lo2 == IF pendingDir = "older" THEN coLo - n ELSE Max(coLo, coHi + n - Window)
                   hi2 == IF pendingDir = "older" THEN Min(coHi, coLo - n + Window) ELSE coHi + n
               IN /\ coLo' = lo2 /\ coHi' = hi2
                  /\ coAtStart' = (lo2 = 0 \/ (pendingDir = "older" /\ n = 0))
                  /\ pending' = 0
                  /\ out' = <<[kind |-> "ctrlo_show", lo |-> lo2, hi |-> hi2]>>
          ELSE /\ out' = <<>> /\ UNCHANGED <<coLo, coHi, coAtStart, pending>>
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, pendingDir,
                   nextToken, alive, cycleStarts>>

\* A lost reply: the shell times the read out.
LogReadFailed(token) ==
    /\ alive /\ ~OnlyOlder /\ token \in 1..(nextToken - 1)
    /\ act' = [name |-> "LogReadFailed", token |-> token]
    /\ IF coOpen /\ pending = token THEN pending' = 0 ELSE UNCHANGED pending
    /\ out' = <<>>
    /\ UNCHANGED <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pendingDir, nextToken, alive, cycleStarts>>

\* A crash at any step loses memory; the log keeps what it held (D7). Under
\* OnlyOlder a crash may happen before Ctrl+O opens so Resumed can expose
\* pre-compaction log reads.
Crash ==
    /\ alive /\ Saved /\ (~OnlyOlder \/ ~coOpen)
    /\ alive' = FALSE /\ out' = <<>> /\ act' = [name |-> "Crash"]
    /\ UNCHANGED <<core, cycleStarts>>

\* After a crash, or after SessionCleared when switching sessions in the same
\* process (/resume): the core starts from the log's last cycle `[last, saved)`.
\* Under OnlyOlder it runs only while Ctrl+O is closed.
ResumedCrash ==
    /\ Saved /\ ~alive
    /\ LET last == SetMax({c \in cycleStarts : c <= savedThrough}) IN
       /\ alive' = TRUE
       /\ nextSeq' = savedThrough /\ cycleFirst' = last /\ heldFirst' = last
       /\ cycleStarts' = {c \in cycleStarts : c <= savedThrough}
       /\ live' = {} /\ turnOpen' = FALSE
       /\ reprinting' = TRUE /\ paintedThrough' = last
       /\ coOpen' = FALSE /\ coLo' = 0 /\ coHi' = 0 /\ coAtStart' = FALSE
       /\ pending' = 0
       /\ out' = <<[kind |-> "reprint_begin"]>> /\ act' = [name |-> "Resumed"]
       /\ nextToken' = 1 /\ pendingDir' = "older"
       /\ UNCHANGED <<cycle, savedThrough>>

ResumedSession ==
    /\ Saved /\ alive /\ ~OnlyOlder /\ nextSeq = heldFirst
    /\ \E ns \in 0..MaxSeq, cf \in 0..MaxSeq :
       /\ cf <= ns
       /\ alive' = TRUE
       /\ cycle' = IF cf = 0 THEN 0 ELSE 1
       /\ cycleFirst' = cf /\ heldFirst' = cf /\ nextSeq' = ns /\ savedThrough' = ns
       /\ cycleStarts' = IF cf = 0 THEN {0} ELSE {0, cf}
       /\ live' = {} /\ turnOpen' = FALSE
       /\ reprinting' = TRUE /\ paintedThrough' = cf
       /\ coOpen' = FALSE /\ coLo' = 0 /\ coHi' = 0 /\ coAtStart' = FALSE
       /\ pending' = 0
       /\ out' = <<[kind |-> "reprint_begin"]>> /\ act' = [name |-> "Resumed"]
       /\ nextToken' = 1 /\ pendingDir' = "older"

Resumed == ResumedCrash \/ ResumedSession

-----------------------------------------------------------------------------

UserMoves ==
    \/ TurnStarted \/ TurnEnded
    \/ \E id \in Ids : BlockOpened(id) \/ BlockChanged(id) \/ BlockFinished(id)
    \/ Compacted \/ Resized \/ ReprintTick \/ SessionCleared
    \/ CtrlOOpened \/ CtrlOScrolledOlder \/ CtrlOScrolledNewer \/ CtrlOClosed

EnvMoves ==
    \/ \E t \in 1..MaxSeq : SavedThrough(t)
    \/ \E t \in 1..MaxTokens, c \in 0..(Step + 1) : LogReadDone(t, c)
    \/ \E t \in 1..MaxTokens : LogReadFailed(t)
    \/ Crash \/ Resumed

\* The screen as the paint effects leave it: a resize, resume, or session clear
\* wipes it, and every paint adds its blocks.
PaintedBy(o) ==
    UNION {IF o[i].kind = "paint_final" THEN {o[i].seq}
           ELSE IF o[i].kind = "reprint_slice" THEN o[i].from..(o[i].to - 1)
           ELSE {} : i \in DOMAIN o}
PaintedUpdate ==
    painted' = IF act'.name \in {"Resized", "Resumed", "SessionCleared"} THEN {} ELSE painted \cup PaintedBy(out')

Next == (UserMoves \/ EnvMoves) /\ PaintedUpdate

\* The pending read answered with the right count.
GoodReply == LogReadDone(pending, Min(Step, Available(pendingDir)))

\* Each fair action carries the screen update, since alone it leaves `painted'` open.
Fairness ==
    /\ WF_vars(ReprintTick /\ PaintedUpdate)
    /\ WF_vars((\E t \in 1..MaxSeq : SavedThrough(t)) /\ PaintedUpdate)
    /\ WF_vars(TurnEnded /\ PaintedUpdate)
    /\ WF_vars((\E id \in Ids : BlockFinished(id)) /\ PaintedUpdate)
    \* Only recovery after a crash is owed; a /resume is the user's choice.
    /\ WF_vars(~alive /\ Resumed /\ PaintedUpdate)
    /\ SF_vars(GoodReply /\ PaintedUpdate)
    /\ (OnlyOlder => WF_vars(CtrlOScrolledOlder /\ PaintedUpdate))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Laws (design/DESIGN.md).

TypeOK ==
    /\ cycle \in 0..MaxCycles
    /\ cycleFirst \in 0..MaxSeq /\ heldFirst \in 0..MaxSeq
    /\ nextSeq \in 0..MaxSeq /\ savedThrough \in 0..MaxSeq
    /\ heldFirst <= cycleFirst /\ cycleFirst <= nextSeq
    /\ live \subseteq Ids /\ turnOpen \in BOOLEAN
    /\ paintedThrough \in 0..MaxSeq /\ reprinting \in BOOLEAN
    /\ coOpen \in BOOLEAN /\ coLo \in 0..MaxSeq /\ coHi \in 0..MaxSeq
    /\ pending \in 0..MaxTokens /\ nextToken \in 1..(MaxTokens + 1)
    /\ alive \in BOOLEAN

\* L2: drops never happen with live blocks or an open turn of the current
\* session, and never drop blocks of the active session.
LiveNeverDropped ==
    \A e \in Effects : e.kind = "drop" => (act.name = "SessionCleared" /\ live = {} /\ ~turnOpen)

\* L3: drops cover only the departing session's held range on a session change.
DropOnlyOldSession ==
    \A e \in Effects : e.kind = "drop" => (act.name = "SessionCleared" /\ e.from < e.to /\ nextSeq = 0 /\ heldFirst = 0)

\* L5
PaintOnceInOrder ==
    /\ (alive /\ ~reprinting) => paintedThrough = nextSeq
    /\ \A e \in Effects : e.kind = "paint_final" => e.seq = nextSeq - 1

\* L6
ReprintInOrder == (alive /\ reprinting) => (heldFirst <= paintedThrough /\ paintedThrough <= nextSeq)

\* L7
ReprintSliceBound ==
    \A e \in Effects : e.kind = "reprint_slice" => (e.from < e.to /\ e.to - e.from <= Slice)

\* L8
CtrlOWindowBound ==
    coOpen => (coLo <= coHi /\ coHi <= nextSeq /\ coHi - coLo <= Window)

\* L9
OneReadInFlight == pending # 0 => coOpen

\* L12
NoReadWhenUnsaved == ~Saved => \A e \in Effects : e.kind # "read_log"

\* L19: outside a reprint, every held block is on the screen.
ScreenHoldsHeld == (alive /\ ~reprinting) => (heldFirst..(nextSeq - 1)) \subseteq painted

\* L13
RecoveredFromLog ==
    act.name = "Resumed" =>
        /\ nextSeq = savedThrough /\ cycleFirst \in cycleStarts /\ heldFirst = cycleFirst
        \* Nothing of the earlier state survives.
        /\ live = {} /\ ~turnOpen /\ ~coOpen /\ pending = 0

\* L1 (action property): while a session stays active, `heldFirst` never advances.
HeldIsCurrentSession ==
    [][(act'.name \notin {"SessionCleared", "Resumed"} /\ alive') => heldFirst' = heldFirst]_vars

\* L4 (action property): a change to a live block touches nothing else.
UpdateIsLocal ==
    [][(act'.name = "BlockChanged") =>
        (UNCHANGED core /\ Len(out') = 1 /\ out'[1].kind = "repaint_block")]_vars

\* L10 (action property): Ctrl+O opens on the newest held blocks and reads nothing.
OpenReadsNothing ==
    [][(act'.name = "CtrlOOpened") =>
        /\ \A i \in DOMAIN out' : out'[i].kind # "read_log"
        /\ coHi' = nextSeq /\ coLo' >= heldFirst]_vars

\* L14 (action property): leaving or clearing a session drops all held blocks of the old session.
OldSessionDroppedOnChange ==
    [][(act'.name = "SessionCleared") =>
        (IF heldFirst < nextSeq
            THEN Len(out') = 1 /\ out'[1] = [kind |-> "drop", from |-> heldFirst, to |-> nextSeq]
            ELSE out' = <<>>)]_vars

\* L18 (action property): no drop ever happens except on a session change.
NoDropDuringSession ==
    [][(\E i \in DOMAIN out' : out'[i].kind = "drop") => act'.name = "SessionCleared"]_vars

\* L22 (action property): a compaction keeps all history held and emits no drop.
CompactionKeepsHistory ==
    [][(act'.name = "Compacted") => (heldFirst' = heldFirst /\ out' = <<>>)]_vars

\* L21 (action property): one log reply brings at most Step blocks.
ReadBounded ==
    [][(act'.name = "LogReadDone") => (coLo - coLo' <= Step /\ coHi' - coHi <= Step)]_vars

\* L11 (action property): a reply whose token is not the pending one changes nothing.
StaleReadIgnored ==
    [][((act'.name = "LogReadDone" \/ act'.name = "LogReadFailed") /\ ~(coOpen /\ pending # 0 /\ act'.token = pending))
        => UNCHANGED core]_vars

\* L20 (action property): no step paints a block already on the screen.
PaintedOnce == [][PaintedBy(out') \cap (IF act'.name \in {"Resized", "Resumed", "SessionCleared"} THEN {} ELSE painted) = {}]_vars

\* L15: a reprint finishes unless another resize, resume, or session clear resets it.
ReprintFinishes == (alive /\ reprinting) ~> (~reprinting \/ ~alive \/ act.name \in {"Resized", "Resumed", "SessionCleared"})

\* L16: with OnlyOlder, a saved session's reader reaches the log's start.
CtrlOReachesStart == (OnlyOlder /\ coOpen) ~> (coLo = 0)
====
