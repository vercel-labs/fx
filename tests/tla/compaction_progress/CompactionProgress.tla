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
(* The row is handed the time: by the worker with each request and each    *)
(* rise of the count, and by the UI's tick. Only time that passed forward  *)
(* counts as waiting, so the system clock can be set back without taking   *)
(* anything from the number. The number is read from the state alone.      *)
(*                                                                         *)
(* The arithmetic gives the code's own whole numbers: the row counts in    *)
(* hundredths of a percent up to Top, and a share is in ten-thousandths.   *)
(* Time counts ticks of 20 seconds and starts at 1. WaitHalf is 3 ticks,   *)
(* the code's 60 seconds.                                                  *)
(*                                                                         *)
(* Bug plants one defect for the configs that must fail:                   *)
(*   today       a waiting request earns nothing (fx before the change)    *)
(*   ask_resets  a new request starts the row again from zero              *)
(*   no_rebase   a new request counts notes the row already shows          *)
(*   thaw        the wait keeps earning after the notes arrive             *)
(*   unbounded   a wait can earn all the room that is left                 *)
(*   no_cap      the row can reach 100% before saving                      *)
(*   keeps_old   a new compaction starts from the last one's numbers       *)
(*   clock_back  a clock set back takes the wait back with it              *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS
    MaxTime,   \* the last tick the clock reaches
    MaxBacks,  \* how many times the system clock is set back
    Levels,    \* the notes' counts the model writes
    Bug

All == 99         \* compaction_progress.all_notes
Scale == 10000    \* share_scale
WaitHalf == 3     \* wait_half_ms, in ticks
SteadyWait == 10  \* ticks: the first 200 seconds of a wait
Top == IF Bug = "no_cap" THEN 10000 ELSE All * 100
WaitShare == IF Bug = "unbounded" THEN Scale ELSE 5000

ASSUME MaxTime \in 2..11
ASSUME MaxBacks \in 0..2
ASSUME Levels \subseteq 1..All
ASSUME Bug \in {"none", "today", "ask_resets", "no_rebase", "thaw", "unbounded", "no_cap", "keeps_old",
                 "clock_back"}

Phases == {"none", "preparation", "summary", "publication"}

\* The phases whose row shows a number.
Counting(p) == p \in {"preparation", "summary", "publication"}

\* The longest wait the model counts: every tick, and every tick again after
\* each time the clock is set back.
MaxWait == MaxTime * (MaxBacks + 1)

VARIABLES
    now,      \* the system clock, in ticks; it can be set back
    phase,    \* the compaction on the row; "none" shows no row
    floor,    \* Progress.floor
    base,     \* Progress.base
    notes,    \* Progress.notes
    waiting,  \* Progress.waiting
    waited,   \* Progress.waited_ms, in ticks
    seen,     \* Progress.seen_ms, in ticks; 0 before the row was handed a time
    backs,    \* how many times the clock was set back, which bounds the model
    row       \* Operation.percent: the number the row shows, or 0 without a row

marks == <<floor, base, notes, waiting, waited, seen>>
vars == <<now, phase, floor, base, notes, waiting, waited, seen, backs, row>>

TypeOK ==
    /\ now \in 1..MaxTime
    /\ phase \in Phases
    /\ floor \in 0..10000
    /\ base \in 0..All /\ notes \in 0..All
    /\ waiting \in BOOLEAN
    /\ waited \in 0..MaxWait
    /\ seen \in 0..MaxTime
    /\ backs \in 0..MaxBacks
    /\ row \in 0..100

\* Progress.waitShare: what a wait of w ticks earns.
Head(w) == IF Bug = "today" THEN 0 ELSE (WaitShare * w) \div (w + WaitHalf)

\* Progress.value after a wait of w ticks, in hundredths of a percent. The
\* code divides once:
\*   floor + room * (head * span + (Scale - head) * fresh) / (Scale * span)
\* TLC's integers have 32 bits, which that product passes, so the model
\* divides in steps that give the same whole number: Fill is
\* (rest * fresh) \div span.
ValueAfter(w) ==
    LET room == Top - floor
        span == All - base
        fresh == notes - base
        rest == room * (Scale - Head(w))
        Fill == IF span = 0 THEN 0
                ELSE (rest \div span) * fresh + ((rest % span) * fresh) \div span
    IN floor + (room * Head(w) + Fill) \div Scale

Value == ValueAfter(waited)

\* Progress.shown
Count == Value \div 100

\* Operation.percent
ShownPct ==
    CASE phase = "summary" -> Count
      [] phase = "publication" -> 100
      [] OTHER -> 0

\* Progress.observed: the wait after the row is handed the time t. Only time
\* that passed forward since the time before counts.
WaitedAt(t) ==
    IF waiting /\ t > seen THEN waited + (t - seen)
    ELSE IF Bug = "clock_back" /\ waiting /\ t < seen
           THEN (IF waited > seen - t THEN waited - (seen - t) ELSE 0)
           ELSE waited

Init ==
    /\ now = 1
    /\ phase = "none"
    /\ floor = 0 /\ base = 0 /\ notes = 0
    /\ waiting = FALSE /\ waited = 0 /\ seen = 0
    /\ backs = 0
    /\ row = 0

\* State.begin, then running(.preparation): a new Operation with a new
\* Progress.
Begin ==
    /\ phase = "none"
    /\ phase' = "preparation"
    /\ IF Bug = "keeps_old"
         THEN UNCHANGED marks
         ELSE /\ floor' = 0 /\ base' = 0 /\ notes' = 0
              /\ waiting' = FALSE /\ waited' = 0 /\ seen' = 0
    /\ UNCHANGED <<now, backs>>
    /\ row' = ShownPct'

\* State.running(.summary): fx is about to ask for the summary.
Summarize ==
    /\ phase = "preparation"
    /\ phase' = "summary"
    /\ UNCHANGED <<now, marks, backs>>
    /\ row' = ShownPct'

\* Progress.asked: a summary request is sent. The first request, a follow-up
\* for turns the notes left out, another model after a failure, and each
\* part of a conversation too large for one request all come here.
Ask ==
    /\ phase = "summary"
    /\ floor' = IF Bug = "ask_resets" THEN 0 ELSE ValueAfter(WaitedAt(now))
    /\ base' = IF Bug = "no_rebase" THEN base ELSE notes
    /\ waited' = 0
    /\ waiting' = TRUE
    /\ seen' = now
    /\ UNCHANGED <<now, phase, notes, backs>>
    /\ row' = ShownPct'

\* Progress.written: the notes' count rose to n. A count that is not higher
\* changes nothing, so the model leaves it out.
Write(n) ==
    /\ phase = "summary"
    /\ n > notes
    /\ notes' = n
    /\ waited' = WaitedAt(now)
    /\ waiting' = IF Bug = "thaw" THEN waiting ELSE FALSE
    /\ seen' = now
    /\ UNCHANGED <<now, phase, floor, base, backs>>
    /\ row' = ShownPct'

\* State.running(.publication): fx saves the summary.
Save ==
    /\ phase = "summary"
    /\ phase' = "publication"
    /\ UNCHANGED <<now, marks, backs>>
    /\ row' = ShownPct'

\* State.settle: the row goes away.
Settle ==
    /\ Counting(phase)
    /\ phase' = "none"
    /\ UNCHANGED <<now, marks, backs>>
    /\ row' = ShownPct'

\* State.observed: the UI's tick hands the row the time t while a compaction
\* is on the row.
Observe(t) ==
    IF Counting(phase)
      THEN waited' = WaitedAt(t) /\ seen' = t
      ELSE UNCHANGED <<waited, seen>>

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ Observe(now + 1)
    /\ UNCHANGED <<phase, floor, base, notes, waiting, backs>>
    /\ row' = ShownPct'

\* The system clock is set back to an earlier time, and the UI's tick hands
\* that time to the row.
ClockBack ==
    /\ backs < MaxBacks
    /\ backs' = backs + 1
    /\ \E t \in 1..(now - 1) :
        /\ now' = t
        /\ Observe(t)
    /\ UNCHANGED <<phase, floor, base, notes, waiting>>
    /\ row' = ShownPct'

Next ==
    \/ Begin
    \/ Summarize
    \/ Ask
    \/ \E n \in Levels : Write(n)
    \/ Save
    \/ Settle
    \/ Tick
    \/ ClockBack

Spec == Init /\ [][Next]_vars

\* ---- the rules ----

\* While the row shows a number it never goes down, whichever way the clock
\* goes.
CountNeverFalls == [][Counting(phase) /\ Counting(phase') => ShownPct' >= ShownPct]_vars

\* The row is not stuck while the model reads: for the first 200 seconds that
\* the first request waits, the number rises with every 20 seconds.
WaitingMoves ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ waiting /\ waiting' /\ floor = 0 /\ floor' = 0
       /\ waited' > waited /\ waited' <= SteadyWait
       => ShownPct' > ShownPct]_vars

\* In those 200 seconds every waiting request keeps earning while two percent
\* of room is left. After them 20 seconds can earn less than the smallest
\* step the row counts.
EveryWaitMoves ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ waiting /\ waiting'
       /\ waited' > waited /\ waited' <= SteadyWait
       /\ Top - Value >= 200
       => Value' > Value]_vars

\* A wait earns at most half of the room that was left when its request was
\* sent, so the row never runs further ahead of the notes than that.
WaitIsBounded == phase = "summary" /\ notes = base => 2 * (Value - floor) <= Top - floor

\* Once a request's notes arrive, only notes move the row.
OnlyNotesMoveAfterNotes ==
    [][/\ phase = "summary" /\ phase' = "summary"
       /\ notes > base /\ notes' = notes /\ base' = base
       => Value' = Value]_vars

\* A new request goes on from the number the row shows.
AskKeepsTheCount == [][Ask => Value' = Value]_vars

\* 100% shows only while fx saves the summary.
FullOnlyWhenSaving == Counting(phase) /\ ShownPct = 100 => phase = "publication"

\* With no wait the row shows the notes' own count.
ExactWithoutWaiting == phase = "summary" /\ floor = 0 /\ waited = 0 => Count = notes

\* When every note is written the row shows 99%, however long the model read.
AllWrittenShows99 == phase = "summary" /\ notes = All => Count = 99

\* A new compaction starts with clean numbers.
StartsClean == phase = "preparation" => floor = 0 /\ base = 0 /\ notes = 0 /\ ~waiting /\ waited = 0

\* The driver's copy of the number is the number.
RowIsShown == row = ShownPct
=============================================================================
