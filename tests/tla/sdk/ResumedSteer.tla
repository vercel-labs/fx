---------------------------- MODULE ResumedSteer ----------------------------
(***************************************************************************)
(* What a reader of a libfx session sees of the steers a resumed turn      *)
(* places.                                                                 *)
(*                                                                         *)
(* A steer sent while the turn waits for a tool is accepted: the journal   *)
(* records it and the running core queues it. When the tool returns, the   *)
(* turn takes the steer at that boundary, shows it as a `user_message`,    *)
(* and the progress before the next model request places it (ToolEnd). A   *)
(* deadline hand-off or a crash ends the run first. The journal still      *)
(* holds the steer as accepted and unplaced, and the resume gives it to    *)
(* the model with the cut-off call's result (Resume). Before this model    *)
(* the resume showed nothing for it (PublishAt = "never").                 *)
(*                                                                         *)
(* The resumed turn shows each steer it places once the progress that      *)
(* places it is written (PublishAt = "progress", Publish). It does not     *)
(* show one at the resume, because a resumed turn that is cancelled        *)
(* before its first request hands the steer back, and the model never      *)
(* got it (PublishAt = "resume").                                          *)
(*                                                                         *)
(* A durable session's reader sees its stream. The resumed turn reads      *)
(* the stream once after `turn_resume` and drops a line the stream         *)
(* already holds (Dedupe). That covers a crash after a boundary showed a   *)
(* steer and before the progress placed it (TakeCrash): the resume places  *)
(* the same steer and would show it again. A plain engine has no stream    *)
(* and cannot tell, so its host sees the line twice (Durable = FALSE).     *)
(*                                                                         *)
(* A crash after the progress that places a resumed steer and before its   *)
(* line is written loses the line, and nothing shows it later: the next    *)
(* resume finds the steer placed (Crash while unpub holds; `lost`). The    *)
(* model keeps this window as a stated limit, and Window shows it.         *)
(*                                                                         *)
(* This model is separate from DurableSteer.tla, which places each steer   *)
(* in the model's context and does not follow what a reader sees. `act`    *)
(* names each step so that tests/tla/drivers/drive-resumed-steer.mjs can   *)
(* drive the real code along any path of the state graph.                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Steers,     \* the steering messages the user may send
    MaxStops,   \* deadline hand-offs and crashes
    MaxCancels, \* user cancels
    PublishAt,  \* when the resume shows a steer it places: "never", "resume" or "progress"
    Durable,    \* the reader sees the session's stream
    Dedupe      \* a durable session drops a line its stream already holds

ASSUME PublishAt \in {"never", "resume", "progress"}
ASSUME Durable \in BOOLEAN /\ Dedupe \in BOOLEAN

None == "none"

VARIABLES
    jr,      \* the journal's record of each steer: "none", "accepted", "placed", "handed"
    mem,     \* where the running core holds each steer: "out", "queued", "resumed", "placed"
    shown,   \* the lines a reader sees for each steer
    via,     \* the lines the resume shows for each steer
    lost,    \* steers placed by a resume whose line a crash lost
    unpub,   \* steers a resume placed and has not shown yet
    run,     \* the run: "up", "down" (handed off or crashed), "done" (the turn ended)
    phase,   \* "tool" while the call runs, "gen" once the request carries the steers
    stops,   \* hand-offs and crashes so far
    cancels, \* cancels so far
    act      \* the step that led here

vars == <<jr, mem, shown, via, lost, unpub, run, phase, stops, cancels, act>>

Names == {"Init", "Send", "ToolEnd", "Publish", "Reply", "Cancel", "Handoff", "Crash", "TakeCrash", "Resume"}

TypeOK ==
    /\ jr \in [Steers -> {"none", "accepted", "placed", "handed"}]
    /\ mem \in [Steers -> {"out", "queued", "resumed", "placed"}]
    /\ shown \in [Steers -> 0..(MaxStops + 2)]
    /\ via \in [Steers -> 0..(MaxStops + 2)]
    /\ lost \subseteq Steers /\ unpub \subseteq Steers
    /\ run \in {"up", "down", "done"} /\ phase \in {"tool", "gen"}
    /\ stops \in 0..MaxStops /\ cancels \in 0..MaxCancels
    /\ act \in [name: Names, m: Steers \cup {None}]

Init ==
    /\ jr = [s \in Steers |-> "none"]
    /\ mem = [s \in Steers |-> "out"]
    /\ shown = [s \in Steers |-> 0]
    /\ via = [s \in Steers |-> 0]
    /\ lost = {} /\ unpub = {}
    /\ run = "up" /\ phase = "tool"
    /\ stops = 0 /\ cancels = 0
    /\ act = [name |-> "Init", m |-> None]

Queued == {s \in Steers : mem[s] = "queued"}
Resumed == {s \in Steers : mem[s] = "resumed"}

\* No resumed steer waits to be shown, so the run takes its next step.
Idle == unpub = {}

\* The lines the resume adds for `S`: a durable session drops one its stream
\* already holds.
Appended(S) == {s \in S : ~(Durable /\ Dedupe /\ shown[s] >= 1)}
Show(S) ==
    /\ shown' = [s \in Steers |-> IF s \in Appended(S) THEN shown[s] + 1 ELSE shown[s]]
    /\ via' = [s \in Steers |-> IF s \in Appended(S) THEN via[s] + 1 ELSE via[s]]

\* A run ends: what the core held in memory is gone.
Forget == mem' = [s \in Steers |-> IF mem[s] \in {"queued", "resumed"} THEN "out" ELSE mem[s]]

\* The user sends a steer while the turn waits for the tool.
Send(s) ==
    /\ run = "up" /\ phase = "tool" /\ Idle
    /\ jr[s] = "none"
    /\ jr' = [jr EXCEPT ![s] = "accepted"]
    /\ mem' = [mem EXCEPT ![s] = "queued"]
    /\ UNCHANGED <<shown, via, lost, unpub, run, phase, stops, cancels>>
    /\ act' = [name |-> "Send", m |-> s]

\* The tool returns. The boundary takes the steers queued and shows each. The
\* progress before the next request places them and the steers the resume
\* holds; the resume's are shown next, once that progress is written.
ToolEnd ==
    /\ run = "up" /\ phase = "tool" /\ Idle
    /\ jr' = [s \in Steers |-> IF s \in Queued \cup Resumed THEN "placed" ELSE jr[s]]
    /\ mem' = [s \in Steers |-> IF s \in Queued \cup Resumed THEN "placed" ELSE mem[s]]
    /\ shown' = [s \in Steers |-> IF s \in Queued THEN shown[s] + 1 ELSE shown[s]]
    /\ unpub' = IF PublishAt = "progress" THEN Resumed ELSE {}
    /\ phase' = "gen"
    /\ UNCHANGED <<via, lost, run, stops, cancels>>
    /\ act' = [name |-> "ToolEnd", m |-> None]

\* The resume shows the steers its progress placed.
Publish ==
    /\ run = "up" /\ unpub # {}
    /\ Show(unpub)
    /\ unpub' = {}
    /\ UNCHANGED <<jr, mem, lost, run, phase, stops, cancels>>
    /\ act' = [name |-> "Publish", m |-> None]

\* The model answers, and the turn ends.
Reply ==
    /\ run = "up" /\ phase = "gen" /\ Idle
    /\ run' = "done"
    /\ UNCHANGED <<jr, mem, shown, via, lost, unpub, phase, stops, cancels>>
    /\ act' = [name |-> "Reply", m |-> None]

\* The user cancels the turn. The steers it never placed are handed back.
Cancel ==
    /\ run = "up" /\ phase = "tool" /\ Idle
    /\ cancels < MaxCancels
    /\ jr' = [s \in Steers |-> IF s \in Queued \cup Resumed THEN "handed" ELSE jr[s]]
    /\ mem' = [s \in Steers |-> IF s \in Queued \cup Resumed THEN "out" ELSE mem[s]]
    /\ run' = "done"
    /\ cancels' = cancels + 1
    /\ UNCHANGED <<shown, via, lost, unpub, phase, stops>>
    /\ act' = [name |-> "Cancel", m |-> None]

\* The deadline stops the worker while the call runs, and the turn is left open.
Handoff ==
    /\ run = "up" /\ phase = "tool" /\ Idle
    /\ stops < MaxStops
    /\ run' = "down" /\ stops' = stops + 1
    /\ Forget
    /\ UNCHANGED <<jr, shown, via, lost, unpub, phase, cancels>>
    /\ act' = [name |-> "Handoff", m |-> None]

\* The process dies at any step. A resumed steer placed and not shown yet is
\* lost to the reader.
Crash ==
    /\ run = "up" /\ stops < MaxStops
    /\ run' = "down" /\ stops' = stops + 1
    /\ Forget
    /\ lost' = lost \cup unpub /\ unpub' = {}
    /\ UNCHANGED <<jr, shown, via, phase, cancels>>
    /\ act' = [name |-> "Crash", m |-> None]

\* The process dies after the boundary took and showed the queued steers and
\* before the progress that places them was written.
TakeCrash ==
    /\ run = "up" /\ phase = "tool" /\ Idle
    /\ Queued # {} /\ stops < MaxStops
    /\ shown' = [s \in Steers |-> IF s \in Queued THEN shown[s] + 1 ELSE shown[s]]
    /\ run' = "down" /\ stops' = stops + 1
    /\ Forget
    /\ UNCHANGED <<jr, via, lost, unpub, phase, cancels>>
    /\ act' = [name |-> "TakeCrash", m |-> None]

\* A new run continues the open turn. It runs the cut-off call again and
\* holds the steers the journal accepted and never placed.
Resume ==
    /\ run = "down"
    /\ run' = "up" /\ phase' = "tool"
    /\ mem' = [s \in Steers |-> IF jr[s] = "accepted" THEN "resumed" ELSE mem[s]]
    /\ IF PublishAt = "resume"
          THEN Show({s \in Steers : jr[s] = "accepted"})
          ELSE UNCHANGED <<shown, via>>
    /\ UNCHANGED <<jr, lost, unpub, stops, cancels>>
    /\ act' = [name |-> "Resume", m |-> None]

Next ==
    \/ \E s \in Steers : Send(s)
    \/ ToolEnd \/ Publish \/ Reply \/ Cancel \/ Handoff \/ Crash \/ TakeCrash \/ Resume

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A durable session shows a steer once.
ShownOnce == \A s \in Steers : shown[s] <= 1

\* A steer the journal placed is on the reader's view, unless its line is
\* still to be written or a crash fell between the progress and the line.
SeenOrLost == \A s \in Steers : jr[s] = "placed" => shown[s] >= 1 \/ s \in lost \/ s \in unpub

\* What a resume shows is a steer its progress already placed. A steer shown
\* earlier, at the resume, can be handed back by a cancel before the model
\* got it.
ResumeShowsPlaced == \A s \in Steers : via[s] >= 1 => jr[s] = "placed"

\* No steer is lost to the reader. It fails: the window above is real.
NeverLost == lost = {}

=============================================================================
