---- MODULE RowOrder ----
\* The agent list's subagent rows, from the moment a turn ends to the moment
\* the list shows it as done, failed, or stopped
\* (src/core/app/app_agents_runtime.zig: `stateOf`, `rowState`, `switchList`,
\* `sortSubagentGroups`, `noteLastEnd`).
\*
\* A row has two parts that come from two threads. Its label, working or not,
\* comes from the subagent's worker, whose flag clears when its turn ends
\* (`finishProcessing`, src/core/agent/worker_runtime.zig). Its place comes
\* from the history, where the reply is saved only when the main loop applies
\* the turn's finish event (src/core/app/app_worker_runtime.zig, `finish_prompt`),
\* which the assistant pacer can hold longer while the reply is shown. Working
\* rows come first in start order, then the rest by newest reply.
\*
\* A row that does not work says how its last applied turn ended: idle when it
\* completed or never ran, failed, or stopped (cancelled by the user, by its
\* parent, or by fx quitting). The end is recorded when the loop applies the
\* turn's finish, the same update that decides the place, and it never changes
\* the place: a failed or stopped row sits where an idle one would. A later turn
\* replaces it. A restart keeps it, in the host's record, and a turn that was
\* going when fx stopped reads as stopped.
\*
\* The rule: a row's label and its place always come from the same applied
\* update. A subagent whose turn has ended but is not applied yet can't show
\* idle, failed, or stopped, because its place would still follow its older
\* history and then move by itself a moment later.
\*
\* The list is drawn at any moment, so what the person sees is a function of
\* the worker flags and the histories: `Shown` and `Order` below. The steps are
\* the ones of one subagent's turn: it starts, its worker finishes, the loop
\* applies the finish, and fx restarts.
\*
\* `Mutation` plants one bug, and each must be caught by its named rule:
\*
\*   worker_flag     the label follows the worker flag alone, so a finished turn
\*                   that is not applied shows idle, placed by its older history
\*                                          IdleRowIsApplied, PlaceChangesWithLabel
\*   end_sorts       a failed or stopped row sorts below the idle ones, so the
\*                   end moves a row   PlaceIgnoresEnd
\*   end_sticks      a completed turn does not clear an earlier failure or stop
\*                                          EndIsOfAppliedTurn
\*   restart_forgets a restart shows every row idle, so a failed or stopped
\*                   row reads as done once fx runs again   RestartKeepsLabel
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    StartOrder,   \* the subagents, in the order they started
    MaxReplies,   \* how many replies the history can take, to keep the model small
    Mutation      \* "none", or the planted bug to check

VARIABLES
    phase,   \* phase[s]: "working" (its worker runs a turn), "ended" (its worker
             \* finished the turn, the loop has not applied it), or "idle"
    reply,   \* reply[s]: the rank of the newest reply in its history, 0 for none
    clock,   \* how many replies the histories hold in all
    end,     \* end[s]: how its last applied turn ended, "done" before it has one
    ending,  \* ending[s]: how the turn its worker finished ended, until applied
    act      \* the step that led here

vars == <<phase, reply, clock, end, ending, act>>

Subs == {StartOrder[i] : i \in DOMAIN StartOrder}
N == Len(StartOrder)
Rank(s) == CHOOSE i \in DOMAIN StartOrder : StartOrder[i] = s

\* How a turn ends: it completes, fails, or is stopped.
Ends == {"done", "failed", "stopped"}

\* What a row that does not work says of its last applied turn: "idle" when it
\* completed or never ran, else how it ended. The footer on the subagent's own
\* screen says "done" for "idle", and the same two words otherwise.
EndLabel(s) == IF end[s] = "done" THEN "idle" ELSE end[s]

\* The label a row shows. A turn that ended but is not applied is still
\* working, until its reply is in the history.
Label(s) ==
    IF phase[s] = "idle" THEN EndLabel(s)
    ELSE IF phase[s] = "working" \/ Mutation # "worker_flag" THEN "working"
    ELSE EndLabel(s)

Shown == [s \in Subs |-> Label(s)]

\* a is listed above b: working rows first in start order, then the rest by
\* newest reply, the earlier starter first among equals, whatever each one's
\* end.
AboveAsIdle(a, b) ==
    IF Label(a) = "working" /\ Label(b) # "working" THEN TRUE
    ELSE IF Label(a) # "working" /\ Label(b) = "working" THEN FALSE
    ELSE IF Label(a) = "working" THEN Rank(a) < Rank(b)
    ELSE reply[a] > reply[b] \/ (reply[a] = reply[b] /\ Rank(a) < Rank(b))

\* The planted bug: a failed or stopped row sorts below an idle one.
Above(a, b) ==
    IF Mutation = "end_sorts" /\ Label(a) = "idle" /\ Label(b) \in {"failed", "stopped"} THEN TRUE
    ELSE IF Mutation = "end_sorts" /\ Label(a) \in {"failed", "stopped"} /\ Label(b) = "idle" THEN FALSE
    ELSE AboveAsIdle(a, b)

Perms == {f \in [1..N -> Subs] : \A i, j \in 1..N : i # j => f[i] # f[j]}

\* The rows as the list draws them.
Order == CHOOSE f \in Perms : \A i, j \in 1..N : i < j => Above(f[i], f[j])

\* The rows as they would sit if no row's end counted.
OrderAsIdle == CHOOSE f \in Perms : \A i, j \in 1..N : i < j => AboveAsIdle(f[i], f[j])

Init ==
    /\ phase = [s \in Subs |-> "idle"]
    /\ reply = [s \in Subs |-> 0]
    /\ clock = 0
    /\ end = [s \in Subs |-> "done"]
    /\ ending = [s \in Subs |-> "done"]
    /\ act = "init"

\* The subagent begins a turn: its worker runs it. How its last one ended
\* stays until this one is applied, but the row says working meanwhile.
Start(s) ==
    /\ phase[s] = "idle"
    /\ phase' = [phase EXCEPT ![s] = "working"]
    /\ act' = "start"
    /\ UNCHANGED <<reply, clock, end, ending>>

\* Its worker ends the turn, as `how`: the flag clears. The reply is not in
\* the history, and the end is not recorded.
WorkerFinish(s, how) ==
    /\ phase[s] = "working"
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ ending' = [ending EXCEPT ![s] = how]
    /\ act' = "finish"
    /\ UNCHANGED <<reply, clock, end>>

\* The main loop applies the turn's finish: the reply is in the history, and
\* the end of the turn is the row's.
Apply(s) ==
    /\ phase[s] = "ended"
    /\ clock < MaxReplies
    /\ clock' = clock + 1
    /\ reply' = [reply EXCEPT ![s] = clock + 1]
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ end' = [end EXCEPT ![s] =
            IF Mutation = "end_sticks" /\ end[s] # "done" /\ ending[s] = "done"
            THEN end[s]
            ELSE ending[s]]
    /\ ending' = [ending EXCEPT ![s] = "done"]
    /\ act' = "apply"

\* fx stops and runs again on the same session. Its worker is gone, so a turn
\* that was going, or ended but was not applied, was cancelled: it reads as
\* stopped. The host saved how every other row's last turn ended, so each
\* keeps it.
Restart ==
    /\ phase' = [s \in Subs |-> "idle"]
    /\ end' = [s \in Subs |->
            IF Mutation = "restart_forgets" THEN "done"
            ELSE IF phase[s] = "idle" THEN end[s]
            ELSE "stopped"]
    /\ ending' = [s \in Subs |-> "done"]
    /\ act' = "restart"
    /\ UNCHANGED <<reply, clock>>

Next ==
    \/ \E s \in Subs : Start(s) \/ Apply(s) \/ (\E how \in Ends : WorkerFinish(s, how))
    \/ Restart

Spec == Init /\ [][Next]_vars

----
\* Invariants

TypeOK ==
    /\ phase \in [Subs -> {"idle", "working", "ended"}]
    /\ reply \in [Subs -> 0..MaxReplies]
    /\ clock \in 0..MaxReplies
    /\ end \in [Subs -> Ends]
    /\ ending \in [Subs -> Ends]
    /\ act \in {"init", "start", "finish", "apply", "restart"}
    /\ Order \in Perms

\* A row that does not show working, whether it shows idle, failed, or
\* stopped, has its finished turn applied: its place already goes by its
\* newest reply.
IdleRowIsApplied == \A s \in Subs : Label(s) # "working" => phase[s] = "idle"

----
\* Action properties

\* The rows change places only in a step that changes a row's label, so the
\* label and the place come from the same update: a row never moves by itself
\* after it shows its new state.
PlaceChangesWithLabel == [][Order' # Order => Shown' # Shown]_vars

\* The rows sit where they would if no row's end counted: a failed or stopped
\* row is placed as an idle one with the same replies, and a row that works
\* is placed as before.
PlaceIgnoresEnd == Order = OrderAsIdle

\* Applying a turn makes how it ended the row's end, so a later turn that
\* completes clears an earlier failure or stop, and a row's end changes in no
\* other step but a restart.
EndIsOfAppliedTurn ==
    [][/\ \A s \in Subs : (act' = "apply" /\ phase[s] = "ended" /\ phase'[s] = "idle") => end'[s] = ending[s]
       /\ \A s \in Subs : end'[s] # end[s] => act' \in {"apply", "restart"}]_vars

\* A restart keeps what each row said, with the host's record, and a row that
\* worked reads as stopped, as the report to its parent says it was cancelled.
RestartKeepsLabel ==
    [][act' = "restart" =>
        \A s \in Subs : Shown'[s] = IF Shown[s] = "working" THEN "stopped" ELSE Shown[s]]_vars
====
