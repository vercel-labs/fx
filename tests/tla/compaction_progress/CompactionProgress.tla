------------------------- MODULE CompactionProgress -------------------------
(***************************************************************************)
(* The number on the compaction row, such as the 23 in                     *)
(* `Compacting 23% (53s)` (src/core/output/compaction_progress.zig, read   *)
(* through Operation.percent in src/core/output/compaction_activity.zig).  *)
(*                                                                         *)
(* The model writes its notes only after it has read the conversation and  *)
(* reasoned about it, which can take minutes, and the notes' own count     *)
(* cannot move before the first line arrives. So each summary request      *)
(* first earns a share of the room left on the row for the time it waits,  *)
(* and its notes then fill what remains. The share grows with the wait and *)
(* stays under half of that room.                                          *)
(*                                                                         *)
(* The arithmetic gives the code's own whole numbers: the row counts in    *)
(* hundredths of a percent up to Top, and a share is in ten-thousandths.   *)
(* Time counts ticks of 20 seconds and starts at 1, since a 0 mark means   *)
(* no request. WaitHalf is 3 ticks, the code's 60 seconds.                 *)
(*                                                                         *)
(* Bug plants one defect for the configs that must fail:                   *)
(*   today       a waiting request earns nothing (fx before the change)    *)
(*   ask_resets  a new request starts the row again from zero              *)
(*   no_rebase   a new request counts notes the row already shows          *)
(*   thaw        the wait keeps earning after the notes arrive             *)
(*   unbounded   a wait can earn all the room that is left                 *)
(*   no_cap      the row can reach 100% before saving                      *)
(*   keeps_old   a new compaction starts from the last one's numbers       *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS
    MaxTime,  \* the last tick the model reaches
    Levels,   \* the notes' counts the model writes
    Bug

All == 99       \* compaction_progress.all_notes
Scale == 10000  \* share_scale
WaitHalf == 3   \* wait_half_ms, in ticks
Top == IF Bug = "no_cap" THEN 10000 ELSE 9900
WaitShare == IF Bug = "unbounded" THEN Scale ELSE 5000

ASSUME MaxTime \in 2..11
ASSUME Levels \subseteq 1..All
ASSUME Bug \in {"none", "today", "ask_resets", "no_rebase", "thaw", "unbounded", "no_cap", "keeps_old"}

Phases == {"none", "preparation", "summary", "publication"}

\* The phases whose row shows a number.
Counting(p) == p \in {"preparation", "summary", "publication"}

VARIABLES
    now,       \* the current tick
    phase,     \* the compaction on the row; "none" shows no row
    floor,     \* Progress.floor
    base,      \* Progress.base
    notes,     \* Progress.notes
    asked,     \* Progress.asked_ms, in ticks; 0 is no request
    answered,  \* Progress.answered_ms, in ticks; 0 is still waiting
    row        \* Operation.percent: the number the row shows, or 0 without a row

marks == <<floor, base, notes, asked, answered>>
vars == <<now, phase, floor, base, notes, asked, answered, row>>

TypeOK ==
    /\ now \in 1..MaxTime
    /\ phase \in Phases
    /\ floor \in 0..10000
    /\ base \in 0..All /\ notes \in 0..All
    /\ asked \in 0..MaxTime /\ answered \in 0..MaxTime
    /\ row \in 0..100

\* Progress.waitShare: what the request in flight has earned by waiting.
Waited ==
    IF asked = 0 THEN 0
    ELSE (IF answered > 0 /\ Bug # "thaw" THEN answered ELSE now) - asked
Head == IF Bug = "today" THEN 0 ELSE (WaitShare * Waited) \div (Waited + WaitHalf)

\* Progress.value, in hundredths of a percent. The code divides once:
\*   floor + room * (Head * span + (Scale - Head) * fresh) / (Scale * span)
\* TLC's integers have 32 bits, which that product passes, so the model
\* divides in steps that give the same whole number: Fill is
\* (rest * fresh) \div span.
Value ==
    LET room == Top - floor
        span == All - base
        fresh == notes - base
        rest == room * (Scale - Head)
        Fill == IF span = 0 THEN 0
                ELSE (rest \div span) * fresh + ((rest % span) * fresh) \div span
    IN floor + (room * Head + Fill) \div Scale

\* Progress.shown
Count == Value \div 100

\* Operation.percent
ShownPct ==
    CASE phase = "summary" -> Count
      [] phase = "publication" -> 100
      [] OTHER -> 0

Init ==
    /\ now = 1
    /\ phase = "none"
    /\ floor = 0 /\ base = 0 /\ notes = 0 /\ asked = 0 /\ answered = 0
    /\ row = 0

\* State.begin, then running(.preparation): a new Operation with a new
\* Progress.
Begin ==
    /\ phase = "none"
    /\ phase' = "preparation"
    /\ IF Bug = "keeps_old"
         THEN UNCHANGED marks
         ELSE floor' = 0 /\ base' = 0 /\ notes' = 0 /\ asked' = 0 /\ answered' = 0
    /\ UNCHANGED now
    /\ row' = ShownPct'

\* State.running(.summary): fx is about to ask for the summary.
Summarize ==
    /\ phase = "preparation"
    /\ phase' = "summary"
    /\ UNCHANGED <<now, marks>>
    /\ row' = ShownPct'

\* Progress.asked: a summary request is sent. The first request, a follow-up
\* for turns the notes left out, another model after a failure, and each
\* part of a conversation too large for one request all come here.
Ask ==
    /\ phase = "summary"
    /\ floor' = IF Bug = "ask_resets" THEN 0 ELSE Value
    /\ base' = IF Bug = "no_rebase" THEN base ELSE notes
    /\ asked' = now
    /\ answered' = 0
    /\ UNCHANGED <<now, phase, notes>>
    /\ row' = ShownPct'

\* Progress.written: the notes' count rose to n. A count that is not higher
\* changes nothing, so the model leaves it out.
Write(n) ==
    /\ phase = "summary"
    /\ n > notes
    /\ notes' = n
    /\ answered' = IF asked > 0 /\ answered = 0 THEN now ELSE answered
    /\ UNCHANGED <<now, phase, floor, base, asked>>
    /\ row' = ShownPct'

\* State.running(.publication): fx saves the summary.
Save ==
    /\ phase = "summary"
    /\ phase' = "publication"
    /\ UNCHANGED <<now, marks>>
    /\ row' = ShownPct'

\* State.settle: the row goes away.
Settle ==
    /\ Counting(phase)
    /\ phase' = "none"
    /\ UNCHANGED <<now, marks>>
    /\ row' = ShownPct'

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<phase, marks>>
    /\ row' = ShownPct'

Next ==
    \/ Begin
    \/ Summarize
    \/ Ask
    \/ \E n \in Levels : Write(n)
    \/ Save
    \/ Settle
    \/ Tick

Spec == Init /\ [][Next]_vars

\* ---- the rules ----

\* While the row shows a number it never goes down.
CountNeverFalls == [][Counting(phase) /\ Counting(phase') => ShownPct' >= ShownPct]_vars

\* The row is not stuck while the model reads: as long as the first request
\* waits, the number rises with every tick. The model's longest wait is 200
\* seconds. After that a tick can leave the whole number as it is while the
\* value still rises, which EveryWaitMoves requires.
WaitingMoves ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ asked > 0 /\ answered = 0 /\ floor = 0
       /\ now' > now
       => ShownPct' > ShownPct]_vars

\* Every waiting request keeps earning while two percent of room is left.
EveryWaitMoves ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ asked > 0 /\ answered = 0
       /\ now' > now
       /\ Top - Value >= 200
       => Value' > Value]_vars

\* A wait earns at most half of the room that was left when its request was
\* sent, so the row never runs further ahead of the notes than that.
WaitIsBounded == phase = "summary" /\ notes = base => 2 * (Value - floor) <= Top - floor

\* Once a request's notes arrive, only notes move the row.
OnlyNotesMoveAfterNotes ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ answered > 0 /\ answered' = answered
       /\ notes' = notes
       => Value' = Value]_vars

\* A new request goes on from the number the row shows.
AskKeepsTheCount == [][Ask => Value' = Value]_vars

\* 100% shows only while fx saves the summary.
FullOnlyWhenSaving == Counting(phase) /\ ShownPct = 100 => phase = "publication"

\* With no wait the row shows the notes' own count.
ExactWithoutWaiting == phase = "summary" /\ floor = 0 /\ Waited = 0 => Count = notes

\* When every note is written the row shows 99%, however long the model read.
AllWrittenShows99 == phase = "summary" /\ notes = All => Count = 99

\* A new compaction starts with clean numbers.
StartsClean == phase = "preparation" => floor = 0 /\ base = 0 /\ notes = 0 /\ asked = 0 /\ answered = 0

\* The driver's copy of the number is the number.
RowIsShown == row = ShownPct
=============================================================================
