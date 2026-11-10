----------------------------- MODULE TurnClock -----------------------------
(***************************************************************************)
(* The thinking row's clocks (src/core/output/turn_clock.zig).             *)
(*                                                                         *)
(* The turn clock counts the turn's own work. It stops while the turn      *)
(* waits, on an approval or a question or on a compaction, and when the    *)
(* wait ends it goes on from the time it showed when the wait began. A     *)
(* compaction shows a clock of its own that starts at zero, whatever       *)
(* started it: the user's /compact, the context filling up, or a provider  *)
(* overflow.                                                               *)
(*                                                                         *)
(* Two threads share the state. The worker begins, advances, stops, and   *)
(* settles a compaction (compaction_activity.State, under worker_mutex),  *)
(* and the user opens and answers prompts. The UI thread syncs the turn    *)
(* clock with what it reads (syncState in                                  *)
(* src/core/app/app_worker_runtime.zig). Any number of events can land     *)
(* between two syncs. The UI syncs many times a second, so it syncs at     *)
(* least once before the shown second moves: Tick needs `synced`.          *)
(*                                                                         *)
(* Time counts whole seconds and starts at 1, since a 0 mark means no      *)
(* clock. `counted` is the seconds the turn worked while nothing waited.   *)
(*                                                                         *)
(* Bug plants one defect for the configs that must fail:                   *)
(*   today_wait     the turn waits only on prompts (fx before the change)  *)
(*   today_clock    automatic compaction shows the turn clock (fx before)  *)
(*   no_shift       the clock is not moved past a finished wait            *)
(*   visible_holds  failed or cancelled feedback on screen holds the clock *)
(*   stage_restart  each compaction step restarts the compaction clock     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxTime,  \* the last second the model reaches
    Bug

ASSUME MaxTime \in 2..12
ASSUME Bug \in {"none", "today_wait", "today_clock", "no_shift", "visible_holds", "stage_restart"}

Phases == {"none", "preparation", "summary", "publication", "stopping", "failed", "done"}
Origins == {"manual", "automatic"}

\* compaction_activity.Operation.active: preparing, running, or stopping.
Active(p) == p \in {"preparation", "summary", "publication", "stopping"}

VARIABLES
    now,        \* the current second
    turn,       \* a turn is running (StreamState.active)
    prompt,     \* an approval or a question is open
    phase,      \* the compaction operation's phase
    origin,     \* what started it
    opStart,    \* when it began
    compStart,  \* the compaction clock's start mark, as the code keeps it
    started,    \* StreamState.turn_started_ms, in seconds; 0 is no clock
    since,      \* StreamState.waiting_since_ms, in seconds; 0 is not waiting
    synced,     \* the UI has synced since the last event
    counted     \* seconds the turn worked while nothing waited

vars == <<now, turn, prompt, phase, origin, opStart, compStart, started, since, synced, counted>>

TypeOK ==
    /\ now \in 1..MaxTime
    /\ turn \in BOOLEAN /\ prompt \in BOOLEAN
    /\ phase \in Phases /\ origin \in Origins
    /\ opStart \in 0..MaxTime /\ compStart \in 0..MaxTime
    /\ started \in 0..MaxTime /\ since \in 0..MaxTime
    /\ synced \in BOOLEAN /\ counted \in 0..MaxTime

\* turn_clock.waits: what the UI reads as the turn waiting.
Waits ==
    \/ prompt
    \/ CASE Bug = "today_wait" -> FALSE
         [] Bug = "visible_holds" -> Active(phase) \/ phase = "failed"
         [] OTHER -> Active(phase)

\* turn_clock.seconds: the instant the clock reads, frozen while waiting.
Reading == IF since > 0 /\ since < now THEN since ELSE now
TurnShown == IF started = 0 \/ now < started THEN 0 ELSE Reading - started

\* The compaction row's seconds. Before the change an automatic compaction
\* showed the turn's clock.
CompShown == IF Bug = "today_clock" /\ origin = "automatic" THEN TurnShown ELSE now - compStart

Init ==
    /\ now = 1
    /\ turn = FALSE /\ prompt = FALSE
    /\ phase = "none" /\ origin = "manual" /\ opStart = 0 /\ compStart = 0
    /\ started = 0 /\ since = 0
    /\ synced = TRUE /\ counted = 0

\* ---- the UI thread ----

\* turn_clock.sync: a wait starts only on a running turn; when it ends, the
\* start mark moves forward by the wait, so the clock goes on from where it
\* stopped.
Sync ==
    /\ ~synced
    /\ synced' = TRUE
    /\ IF Waits
         THEN /\ since' = IF turn /\ since = 0 THEN now ELSE since
              /\ UNCHANGED started
         ELSE /\ since' = 0
              /\ started' = IF since > 0 /\ started > 0 /\ now > since /\ Bug # "no_shift"
                              THEN started + (now - since)
                              ELSE started
    /\ UNCHANGED <<now, turn, prompt, phase, origin, opStart, compStart, counted>>

\* A turn begins: resetStream, then turn_started_ms = now.
TurnStart ==
    /\ ~turn
    /\ turn' = TRUE /\ started' = now /\ since' = 0 /\ counted' = 0
    /\ synced' = FALSE
    /\ UNCHANGED <<now, prompt, phase, origin, opStart, compStart>>

\* The turn's stream resets (agent.stream = .{}), whatever else is going on.
TurnEnd ==
    /\ turn
    /\ turn' = FALSE /\ prompt' = FALSE /\ started' = 0 /\ since' = 0 /\ counted' = 0
    /\ synced' = FALSE
    /\ UNCHANGED <<now, phase, origin, opStart, compStart>>

\* ---- the user ----

PromptOpen ==
    /\ turn /\ ~prompt
    /\ prompt' = TRUE /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, phase, origin, opStart, compStart, started, since, counted>>

PromptClose ==
    /\ prompt
    /\ prompt' = FALSE /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, phase, origin, opStart, compStart, started, since, counted>>

\* ---- the worker ----

\* State.begin, then running(.preparation). Automatic and overflow compaction
\* run inside a turn; a manual /compact is refused while one runs.
Begin(o) ==
    /\ ~Active(phase)
    /\ IF o = "automatic" THEN turn ELSE ~turn
    /\ phase' = "preparation" /\ origin' = o /\ opStart' = now /\ compStart' = now
    /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, prompt, started, since, counted>>

\* State.running with the next stage.
Advance ==
    /\ phase \in {"preparation", "summary"}
    /\ phase' = IF phase = "preparation" THEN "summary" ELSE "publication"
    /\ compStart' = IF Bug = "stage_restart" THEN now ELSE compStart
    /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, prompt, origin, opStart, started, since, counted>>

\* State.stopping: Esc during compaction.
Stop ==
    /\ phase \in {"preparation", "summary", "publication"}
    /\ phase' = "stopping" /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, prompt, origin, opStart, compStart, started, since, counted>>

\* State.settle. Success leaves nothing on screen; a failure or a cancel
\* keeps its feedback until it is dismissed.
Settle(ok) ==
    /\ Active(phase)
    /\ phase' = IF ok THEN "done" ELSE "failed"
    /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, prompt, origin, opStart, compStart, started, since, counted>>

Dismiss ==
    /\ phase = "failed"
    /\ phase' = "done" /\ synced' = FALSE
    /\ UNCHANGED <<now, turn, prompt, origin, opStart, compStart, started, since, counted>>

\* ---- time ----

Tick ==
    /\ synced
    /\ now < MaxTime
    /\ now' = now + 1
    /\ counted' = IF turn /\ ~prompt /\ ~Active(phase) THEN counted + 1 ELSE counted
    /\ UNCHANGED <<turn, prompt, phase, origin, opStart, compStart, started, since, synced>>

Next ==
    \/ Sync
    \/ TurnStart
    \/ TurnEnd
    \/ PromptOpen
    \/ PromptClose
    \/ \E o \in Origins : Begin(o)
    \/ Advance
    \/ Stop
    \/ \E ok \in BOOLEAN : Settle(ok)
    \/ Dismiss
    \/ Tick

Spec == Init /\ [][Next]_vars

\* ---- the rules ----

\* No second of a compaction is counted on the turn clock.
CompactionTimeExcluded == synced /\ turn /\ Active(phase) => since > 0

\* With nothing waiting the turn clock runs, even while a failed
\* compaction's feedback is still on screen.
RunsWhenNothingWaits == synced /\ turn /\ ~prompt /\ ~Active(phase) => since = 0

\* The turn shows exactly the seconds it worked: it goes on after each wait
\* from where it stopped, never adding the wait and never going back.
TurnClockCountsWork == synced /\ turn => TurnShown = counted

\* A compaction's clock starts at zero when it begins and runs through its
\* steps, whatever started it.
CompactionCountsFromZero == Active(phase) => CompShown = now - opStart
=============================================================================
