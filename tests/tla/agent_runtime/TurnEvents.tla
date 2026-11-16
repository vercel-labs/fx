----------------------------- MODULE TurnEvents -----------------------------
(***************************************************************************)
(* What the agent loop tells one front end about a turn, through           *)
(* AgentRuntimeDeps.emit (src/core/agent/runtime/turn_event.zig and        *)
(* deps.zig).                                                               *)
(*                                                                         *)
(* The loop emits its events one at a time, in its own order. Each event's *)
(* payload is memory the loop allocated. emit lends the event: the front   *)
(* end handles it during the call and copies what it keeps, and the loop   *)
(* frees the payload once emit returns.                                    *)
(*                                                                         *)
(*  - A front end that writes at once, as fx acp and fx ask do, shows the  *)
(*    event during the call.                                               *)
(*  - The TUI (Queued) copies the event into its queue during the call.   *)
(*    Its screen thread shows the copy later, in queue order, and frees   *)
(*    it.                                                                  *)
(*                                                                         *)
(* Today = TRUE is the rule before emit: push_event and push_diff_block   *)
(* took the loop's own payload for those kinds (Owning) and freed it, and  *)
(* the loop didn't.                                                        *)
(* turn-events-today.cfg shows LoopFrees failing.                          *)
(*                                                                         *)
(* Mutation plants one defect, and the rule each turn-events-mutation-*   *)
(* config names must catch it:                                             *)
(*   keep-lent         the TUI queues the lent payload, not a copy         *)
(*   free-in-front     a front end frees a lent payload, as push_event did *)
(*   no-free           the loop never frees what it emitted               *)
(*   drop-kind         a front end drops notices (a catch-all arm)         *)
(*   bypass-queue      the TUI shows text at once, ahead of its queue      *)
(*                                                                         *)
(* Script is the order the loop emits its kinds in. A run of the real fx  *)
(* through tests/tla/drivers/agent_runtime/turn_events.ts sets it from    *)
(* the fake Gateway's replies, and TurnEventsTrace.tla checks that run.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Script,     \* the kinds the loop emits, in order
    Queued,     \* TRUE: the TUI; FALSE: fx acp or fx ask
    Today,      \* the ownership rule before emit
    Mutation    \* "none" or one planted defect

Kinds == {"text", "tool", "diff", "notice", "worker"}
Owning == {"worker", "diff"}    \* the kinds push_event and push_diff_block take
Max == Len(Script)
Mem == {"none", "live", "freed"}

ASSUME \A i \in 1..Max : Script[i] \in Kinds

VARIABLES
    n,          \* events the loop emitted
    inEmit,     \* the event in an emit call, 0 between calls
    buf,        \* [1..Max -> Mem]: each event's payload, the loop's memory
    freedBy,    \* [1..Max -> {"none", "loop", "front"}]
    copy,       \* [1..Max -> Mem]: the front end's or the shim's copy
    aliased,    \* [1..Max -> BOOLEAN]: the queue holds the loop's payload itself
    queue,      \* the TUI's queue, as event numbers
    shown,      \* the events the front end showed, in order
    bad         \* memory was read after it was freed, or freed twice

vars == <<n, inEmit, buf, freedBy, copy, aliased, queue, shown, bad>>

Init ==
    /\ n = 0 /\ inEmit = 0
    /\ buf = [i \in 1..Max |-> "none"]
    /\ freedBy = [i \in 1..Max |-> "none"]
    /\ copy = [i \in 1..Max |-> "none"]
    /\ aliased = [i \in 1..Max |-> FALSE]
    /\ queue = <<>> /\ shown = <<>> /\ bad = FALSE

\* The front end gets the loop's own payload, which it then owns: before
\* emit, for the owning kinds.
HandedOver(k) == Today /\ k \in Owning
Dropped(k) == Mutation = "drop-kind" /\ k = "notice"
\* The TUI keeps the loop's payload itself, not a copy.
Kept(k) == HandedOver(k) \/ Mutation = "keep-lent"

\* The loop emits its next event. The front end handles it during the call.
Emit ==
    /\ inEmit = 0 /\ n < Max
    /\ LET i == n + 1
           k == Script[i]
       IN
       /\ n' = i /\ inEmit' = i
       /\ IF Queued /\ ~Dropped(k) /\ ~(Mutation = "bypass-queue" /\ k = "text")
          THEN \* The TUI queues a copy, or the payload it keeps.
               /\ queue' = Append(queue, i)
               /\ aliased' = [aliased EXCEPT ![i] = Kept(k)]
               /\ copy' = [copy EXCEPT ![i] = IF Kept(k) THEN "none" ELSE "live"]
               /\ shown' = shown
               /\ buf' = [buf EXCEPT ![i] = "live"]
               /\ freedBy' = freedBy
          ELSE \* Shown at once, or dropped. A front end frees what it owns:
               \* a handed-over payload or, by mistake, the lent payload.
               /\ queue' = queue /\ aliased' = aliased
               /\ shown' = IF Dropped(k) THEN shown ELSE Append(shown, i)
               /\ copy' = copy
               /\ IF HandedOver(k) \/ (Mutation = "free-in-front" /\ k \in Owning)
                  THEN /\ buf' = [buf EXCEPT ![i] = "freed"]
                       /\ freedBy' = [freedBy EXCEPT ![i] = "front"]
                  ELSE /\ buf' = [buf EXCEPT ![i] = "live"]
                       /\ freedBy' = freedBy
       /\ UNCHANGED bad

\* emit returns, and the loop frees the payload, unless it handed it over
\* under the old rule.
Return ==
    /\ inEmit # 0
    /\ LET i == inEmit IN
       /\ inEmit' = 0
       /\ IF HandedOver(Script[i]) \/ Mutation = "no-free"
          THEN UNCHANGED <<buf, freedBy, bad>>
          ELSE IF buf[i] = "freed"
               THEN /\ bad' = TRUE
                    /\ UNCHANGED <<buf, freedBy>>
               ELSE /\ buf' = [buf EXCEPT ![i] = "freed"]
                    /\ freedBy' = [freedBy EXCEPT ![i] = "loop"]
                    /\ UNCHANGED bad
    /\ UNCHANGED <<n, copy, aliased, queue, shown>>

\* The TUI's screen thread shows the head of its queue and frees what it
\* held, at any time, also while the loop is in an emit call.
Drain ==
    /\ queue # <<>>
    /\ LET i == Head(queue)
           held == IF aliased[i] THEN buf[i] ELSE copy[i]
       IN
       /\ queue' = Tail(queue)
       /\ shown' = Append(shown, i)
       /\ IF held = "freed"
          THEN /\ bad' = TRUE
               /\ UNCHANGED <<buf, freedBy, copy>>
          ELSE IF aliased[i]
               THEN /\ buf' = [buf EXCEPT ![i] = "freed"]
                    /\ freedBy' = [freedBy EXCEPT ![i] = "front"]
                    /\ UNCHANGED <<copy, bad>>
               ELSE /\ copy' = [copy EXCEPT ![i] = "freed"]
                    /\ UNCHANGED <<buf, freedBy, bad>>
    /\ UNCHANGED <<n, inEmit, aliased>>

Next == Emit \/ Return \/ Drain

Spec == Init /\ [][Next]_vars

Done == n = Max /\ inEmit = 0 /\ queue = <<>>

-----------------------------------------------------------------------------
TypeOK ==
    /\ n \in 0..Max /\ inEmit \in 0..Max
    /\ buf \in [1..Max -> Mem] /\ copy \in [1..Max -> Mem]
    /\ freedBy \in [1..Max -> {"none", "loop", "front"}]
    /\ aliased \in [1..Max -> BOOLEAN]
    /\ \A j \in 1..Len(queue) : queue[j] \in 1..Max
    /\ \A j \in 1..Len(shown) : shown[j] \in 1..Max
    /\ bad \in BOOLEAN

\* Nothing is read after it was freed, and nothing is freed twice.
MemorySafe == ~bad

\* The front end shows the events in the order the loop emitted them.
InOrder == \A a, b \in 1..Len(shown) : a < b => shown[a] < shown[b]

\* Once the turn is over, the front end showed every event.
Complete == Done => shown = [j \in 1..Max |-> j]

\* Once the turn is over, every payload and every copy was freed.
NoLeak == Done => \A j \in 1..Max : buf[j] = "freed" /\ copy[j] \in {"none", "freed"}

\* One rule for every kind: the loop frees what it emitted, never the front
\* end.
LoopFrees == \A j \in 1..Max : buf[j] = "freed" => freedBy[j] = "loop"
=============================================================================
