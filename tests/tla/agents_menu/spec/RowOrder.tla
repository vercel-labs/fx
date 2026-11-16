---- MODULE RowOrder ----
\* The agent list's subagent rows, from the moment a turn ends to the moment
\* the list shows it as done (src/core/app/app_agents_runtime.zig: `stateOf`,
\* `rowState`, `switchList`, `sortSubagentGroups`).
\*
\* A row has two parts that come from two threads. Its label, working or idle,
\* comes from the subagent's worker, whose flag clears when its turn ends
\* (`finishProcessing`, src/core/agent/worker_runtime.zig). Its place comes
\* from the history, where the reply is saved only when the main loop applies
\* the turn's finish event (src/core/app/app_worker_runtime.zig, `finish_prompt`),
\* which the assistant pacer can hold longer while the reply is shown. Working
\* rows come first in start order, then the rest by newest reply.
\*
\* The rule: a row's label and its place always come from the same applied
\* update. A subagent whose turn has ended but is not applied yet can't show
\* idle, because its place would still follow its older history and then move
\* by itself a moment later.
\*
\* The list is drawn at any moment, so what the person sees is a function of
\* the worker flags and the histories: `Shown` and `Order` below. The steps are
\* the ones of one subagent's turn: it starts, its worker finishes, the loop
\* applies the finish.
\*
\* `Mutation` plants one bug, and each must be caught by its named rule:
\*
\*   worker_flag  the label follows the worker flag alone, so a finished turn
\*                that is not applied shows idle, placed by its older history
\*                                            IdleRowIsApplied, PlaceChangesWithLabel
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
    act      \* the step that led here

vars == <<phase, reply, clock, act>>

Subs == {StartOrder[i] : i \in DOMAIN StartOrder}
N == Len(StartOrder)
Rank(s) == CHOOSE i \in DOMAIN StartOrder : StartOrder[i] = s

\* The label a row shows. A turn that ended but is not applied is still
\* working, until its reply is in the history.
Label(s) ==
    IF phase[s] = "idle" THEN "idle"
    ELSE IF phase[s] = "working" \/ Mutation # "worker_flag" THEN "working"
    ELSE "idle"

Shown == [s \in Subs |-> Label(s)]

\* a is listed above b: working rows first in start order, then the rest by
\* newest reply, the earlier starter first among equals.
Above(a, b) ==
    IF Label(a) = "working" /\ Label(b) # "working" THEN TRUE
    ELSE IF Label(a) # "working" /\ Label(b) = "working" THEN FALSE
    ELSE IF Label(a) = "working" THEN Rank(a) < Rank(b)
    ELSE reply[a] > reply[b] \/ (reply[a] = reply[b] /\ Rank(a) < Rank(b))

Perms == {f \in [1..N -> Subs] : \A i, j \in 1..N : i # j => f[i] # f[j]}

\* The rows as the list draws them.
Order == CHOOSE f \in Perms : \A i, j \in 1..N : i < j => Above(f[i], f[j])

Init ==
    /\ phase = [s \in Subs |-> "idle"]
    /\ reply = [s \in Subs |-> 0]
    /\ clock = 0
    /\ act = "init"

\* The subagent begins a turn: its worker runs it.
Start(s) ==
    /\ phase[s] = "idle"
    /\ phase' = [phase EXCEPT ![s] = "working"]
    /\ act' = "start"
    /\ UNCHANGED <<reply, clock>>

\* Its worker ends the turn: the flag clears. The reply is not in the history.
WorkerFinish(s) ==
    /\ phase[s] = "working"
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ act' = "finish"
    /\ UNCHANGED <<reply, clock>>

\* The main loop applies the turn's finish: the reply is in the history.
Apply(s) ==
    /\ phase[s] = "ended"
    /\ clock < MaxReplies
    /\ clock' = clock + 1
    /\ reply' = [reply EXCEPT ![s] = clock + 1]
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ act' = "apply"

Next == \E s \in Subs : Start(s) \/ WorkerFinish(s) \/ Apply(s)

Spec == Init /\ [][Next]_vars

----
\* Invariants

TypeOK ==
    /\ phase \in [Subs -> {"idle", "working", "ended"}]
    /\ reply \in [Subs -> 0..MaxReplies]
    /\ clock \in 0..MaxReplies
    /\ act \in {"init", "start", "finish", "apply"}
    /\ Order \in Perms

\* A row that shows idle has its finished turn applied: its place already goes
\* by its newest reply.
IdleRowIsApplied == \A s \in Subs : Label(s) = "idle" => phase[s] = "idle"

----
\* Action properties

\* The rows change places only in a step that changes a row's label, so the
\* label and the place come from the same update: a row never moves by itself
\* after it shows its new state.
PlaceChangesWithLabel == [][Order' # Order => Shown' # Shown]_vars
====
