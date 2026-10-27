-------------------------------- MODULE Fleet --------------------------------
(***************************************************************************)
(* Step: a fleet worker's turns, its queue, its tombstone, and the parent's *)
(* receipt of each turn's result (D112, D113).                             *)
(*                                                                         *)
(* One worker w. Each accepted input becomes turn job t, numbered in the   *)
(* order the parent accepted it. An idle worker starts it at once; a busy  *)
(* one queues it, unless the running turn is streaming, which takes it as  *)
(* steering and makes no job. A turn's end and the start of the queue's    *)
(* front are one save, unless the turn was cancelled; a pump starts the    *)
(* front of an idle worker's queue. Terminate first cancels and joins the  *)
(* running turn, then makes the worker terminal and discards its queue,    *)
(* whose jobs settle as cancelled and are reported by the terminate        *)
(* itself. A settled result reaches the parent once, through the jobs     *)
(* registry: a waiter's claim or an async notice, whichever takes it first.*)
(*                                                                         *)
(* Design: system-design.md D112, D113. Code:                              *)
(* src/core/session_manager/fold.zig and fold_queue.zig (plan, apply),     *)
(* src/core/subagent/fleet_state.zig, managed_owner.zig (slotMain, finish),*)
(* fleet_host.zig (send, terminate, pumpQueues) and turn_jobs.zig (Ledger).*)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxTurns, MaxQueue

Jobs == 1..MaxTurns

VARIABLES
    lifecycle,  \* "live" or "terminal"
    open,       \* the running turn's job, 0 when idle
    streaming,  \* the running turn takes steering
    queue,      \* the queued jobs, oldest first
    accepted,   \* the newest job number accepted
    job,        \* [Jobs -> state]
    started,    \* the jobs that began to run, in order
    delivered   \* [Jobs -> how many times its result reached the parent]

vars == <<lifecycle, open, streaming, queue, accepted, job, started, delivered>>

States == {"none", "queued", "running", "settled", "discarded"}

TypeOK ==
    /\ lifecycle \in {"live", "terminal"}
    /\ open \in 0..MaxTurns
    /\ streaming \in BOOLEAN
    /\ queue \in Seq(Jobs)
    /\ accepted \in 0..MaxTurns
    /\ job \in [Jobs -> States]
    /\ started \in Seq(Jobs)
    /\ delivered \in [Jobs -> 0..2]

Init ==
    /\ lifecycle = "live"
    /\ open = 0
    /\ streaming = FALSE
    /\ queue = <<>>
    /\ accepted = 0
    /\ job = [t \in Jobs |-> "none"]
    /\ started = <<>>
    /\ delivered = [t \in Jobs |-> 0]

Start(t) ==
    /\ open' = t
    /\ job' = [job EXCEPT ![t] = "running"]
    /\ started' = Append(started, t)

\* The parent sends input: a new turn, a queued one, or steering.
Send ==
    /\ lifecycle = "live"
    /\ \/ /\ open # 0 /\ streaming /\ queue = <<>>
          /\ UNCHANGED <<open, streaming, queue, accepted, job, started>>
       \/ /\ accepted < MaxTurns
          /\ LET t == accepted + 1 IN
             /\ accepted' = t
             /\ IF open = 0 /\ queue = <<>>
                THEN /\ Start(t)
                     /\ streaming' = FALSE
                     /\ UNCHANGED queue
                ELSE /\ Len(queue) < MaxQueue
                     /\ queue' = Append(queue, t)
                     /\ job' = [job EXCEPT ![t] = "queued"]
                     /\ UNCHANGED <<open, streaming, started>>
    /\ UNCHANGED <<lifecycle, delivered>>

\* The running turn reaches its model loop and takes steering from now on.
Stream ==
    /\ open # 0 /\ ~streaming
    /\ streaming' = TRUE
    /\ UNCHANGED <<lifecycle, open, queue, accepted, job, started, delivered>>

\* The running turn ends. Unless it was cancelled, the queue's front starts
\* in the same save.
Settle ==
    /\ open # 0
    /\ \E cancelled \in BOOLEAN :
        IF ~cancelled /\ lifecycle = "live" /\ queue # <<>>
        THEN /\ open' = Head(queue)
             /\ queue' = Tail(queue)
             /\ job' = [job EXCEPT ![open] = "settled", ![Head(queue)] = "running"]
             /\ started' = Append(started, Head(queue))
        ELSE /\ open' = 0
             /\ job' = [job EXCEPT ![open] = "settled"]
             /\ UNCHANGED <<queue, started>>
    /\ streaming' = FALSE
    /\ UNCHANGED <<lifecycle, accepted, delivered>>

\* A pump starts the queue's front of an idle worker: after a cancelled
\* turn, or after a restart.
Pump ==
    /\ lifecycle = "live" /\ open = 0 /\ queue # <<>>
    /\ Start(Head(queue))
    /\ queue' = Tail(queue)
    /\ streaming' = FALSE
    /\ UNCHANGED <<lifecycle, accepted, delivered>>

\* Terminate: the running turn is cancelled and joined first, then the
\* tombstone goes in and the queue is discarded.
Terminate ==
    /\ lifecycle = "live"
    /\ open = 0
    /\ lifecycle' = "terminal"
    /\ queue' = <<>>
    /\ job' = [t \in Jobs |-> IF job[t] = "queued" THEN "discarded" ELSE job[t]]
    /\ UNCHANGED <<open, streaming, accepted, started, delivered>>

\* A settled result reaches the parent: claimed by a waiter, or taken by
\* the parent's next step. Each checks it was not delivered.
Claim(t) ==
    /\ job[t] = "settled" /\ delivered[t] = 0
    /\ delivered' = [delivered EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<lifecycle, open, streaming, queue, accepted, job, started>>

Step(t) ==
    /\ job[t] = "settled" /\ delivered[t] = 0
    /\ delivered' = [delivered EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<lifecycle, open, streaming, queue, accepted, job, started>>

Next ==
    \/ Send \/ Stream \/ Settle \/ Pump \/ Terminate
    \/ \E t \in Jobs : Claim(t) \/ Step(t)

Spec == Init /\ [][Next]_vars /\ WF_vars(Settle) /\ WF_vars(Pump)
             /\ \A t \in Jobs : WF_vars(Step(t))

-----------------------------------------------------------------------------
Range(s) == {s[i] : i \in 1..Len(s)}

\* Queued turns start in the order the parent accepted them.
QueueInOrder ==
    /\ \A i \in 1..Len(started) - 1 : started[i] < started[i + 1]
    /\ \A i \in 1..Len(queue) : open < queue[i]
    /\ \A i \in 1..Len(queue) - 1 : queue[i] < queue[i + 1]

\* A terminal worker runs nothing and holds no queue.
NoWorkAfterTerminate ==
    lifecycle = "terminal" => (open = 0 /\ queue = <<>>)

\* The queue holds exactly the jobs waiting to run.
QueueIsQueued ==
    \A t \in Jobs : (job[t] = "queued") <=> (t \in Range(queue))

\* Each settled result reaches the parent at most once.
ExactlyOnceDelivery ==
    \A t \in Jobs : delivered[t] <= 1

\* Every accepted job eventually settles or is discarded.
EveryJobEnds ==
    \A t \in Jobs : (job[t] \in {"queued", "running"}) ~> (job[t] \in {"settled", "discarded"})
=============================================================================
