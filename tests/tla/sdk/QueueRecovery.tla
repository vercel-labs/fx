--------------------------- MODULE QueueRecovery ---------------------------
(***************************************************************************)
(* Restart recovery on a Workflow World an app shares between libfx        *)
(* sessions and its own Workflow SDK runs (sdk/durable.js createRun and    *)
(* libfx's two queue handlers in createWorldBackend).                      *)
(*                                                                         *)
(* A process that starts the World with recovery on, as world-local and    *)
(* world-postgres do by default, queues one message { runId } for every    *)
(* run still pending or running (@workflow/world reenqueueActiveRuns). The *)
(* message goes on the queue of the namespace the run recorded in          *)
(* run_created's executionContext.queueNamespace, or on the starting       *)
(* process's default queue when it recorded none. The Workflow SDK takes   *)
(* the default queue and fails a run whose workflow it does not have       *)
(* (WorkflowNotRegisteredError). libfx's queue is the "libfx" namespace,   *)
(* __libfx_wkf_workflow_. Its route hands a message to the agent the       *)
(* message names, "default" when it names none, and a recovery message     *)
(* names none: it carries no prompt.                                       *)
(*                                                                         *)
(* libfx's own local() World starts with recovery off, so only a World the *)
(* app starts recovers. A World's queue lives in its process here, so a    *)
(* restart drops the messages the old process had not delivered.           *)
(*                                                                         *)
(* RecordNamespace is the fix: libfx records "libfx" on run_created.       *)
(* AckBare is its other half: libfx's route acknowledges a message that    *)
(* carries no prompt before it looks for an agent, so a process whose      *)
(* agents all have names does not refuse it, which has the World deliver  *)
(* it again and again. QueueRecovery-NoNamespace.cfg is libfx before the   *)
(* fix and QueueRecovery-NoBareAck.cfg the fix without its other half.     *)
(*                                                                         *)
(* A session an older libfx created recorded no namespace, and a World     *)
(* cannot change a run's executionContext, so LibfxRunsNotFailed covers    *)
(* the sessions this libfx creates.                                        *)
(*                                                                         *)
(* QueueRecoveryTrace.tla checks runs of the real SDK against this model;  *)
(* tests/tla/drivers/sdk/queue-recovery.ts records them.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    LibfxRuns,         \* libfx sessions
    AppRuns,           \* the app's own Workflow SDK runs
    RecordNamespace,   \* libfx records queueNamespace "libfx" on run_created
    AckBare,           \* libfx's route acks a message with no prompt at once
    MaxRestarts,       \* processes that start the World after the first
    MaxAttempts        \* deliveries of one message before the World drops it

ASSUME LibfxRuns \cap AppRuns = {}
ASSUME RecordNamespace \in BOOLEAN /\ AckBare \in BOOLEAN
ASSUME MaxRestarts \in Nat /\ MaxAttempts \in Nat \ {0}

Runs == LibfxRuns \cup AppRuns
Kind(r) == IF r \in LibfxRuns THEN "libfx" ELSE "workflow"
\* The agents a process has: one named "default", or only named others.
AgentSets == {"default", "named"}
Topics == {"libfx", "default"}
Consumers == {"libfx", "workflow", "turn", "none"}
Outcomes == {"ran", "failed", "acked", "refused", "dropped", "none"}

VARIABLES
    created,     \* the runs created so far
    ns,          \* ns[r]: the namespace run r recorded, "libfx" or "none"
    status,      \* status[r]: "none" before r exists, then "running" or "failed"
    agents,      \* the agents the running process has
    queue,       \* recovery messages not yet acknowledged
    last,        \* what the last step did to a run: a delivery or a turn
    restarts

vars == <<created, ns, status, agents, queue, last, restarts>>

Message == [run : Runs, topic : Topics, attempts : 0..MaxAttempts]
Nothing == [run |-> "none", consumer |-> "none", outcome |-> "none"]

\* The queue a recovered run goes on: the namespace it recorded, or the
\* default queue of whichever process starts the World.
TopicOf(r) == IF ns[r] = "libfx" THEN "libfx" ELSE "default"
ConsumerOf(topic) == IF topic = "libfx" THEN "libfx" ELSE "workflow"

TypeOK ==
    /\ created \subseteq Runs
    /\ ns \in [Runs -> {"libfx", "none"}]
    /\ status \in [Runs -> {"none", "running", "failed"}]
    /\ agents \in AgentSets
    /\ queue \subseteq Message
    /\ last \in [run : Runs \cup {"none"}, consumer : Consumers, outcome : Outcomes]
    /\ restarts \in 0..MaxRestarts

Init ==
    /\ created = {}
    /\ ns = [r \in Runs |-> "none"]
    /\ status = [r \in Runs |-> "none"]
    /\ agents \in AgentSets
    /\ queue = {}
    /\ last = Nothing
    /\ restarts = 0

\* libfx creates a session's run (sdk/durable.js createRun); the app's
\* Workflow SDK creates its own, on the default queue.
Create(r) ==
    /\ r \notin created
    /\ created' = created \cup {r}
    /\ ns' = [ns EXCEPT ![r] = IF Kind(r) = "libfx" /\ RecordNamespace THEN "libfx" ELSE "none"]
    /\ status' = [status EXCEPT ![r] = "running"]
    /\ last' = Nothing
    /\ UNCHANGED <<agents, queue, restarts>>

\* A new process with agents `a` starts the World. A World the app starts
\* recovers: it queues every active run on the queue that run's namespace
\* names. libfx's own local() World does not.
Restart(a, recover) ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ agents' = a
    /\ queue' = IF recover
                  THEN {[run |-> r, topic |-> TopicOf(r), attempts |-> 0] : r \in {x \in created : status[x] = "running"}}
                  ELSE {}
    /\ last' = Nothing
    /\ UNCHANGED <<created, ns, status>>

\* The Workflow SDK runs the app's own run, and fails one whose workflow it
\* does not have.
WorkflowTakes(m) ==
    /\ ConsumerOf(m.topic) = "workflow"
    /\ queue' = queue \ {m}
    /\ IF Kind(m.run) = "workflow"
         THEN /\ status' = status
              /\ last' = [run |-> m.run, consumer |-> "workflow", outcome |-> "ran"]
         ELSE /\ status' = [status EXCEPT ![m.run] = "failed"]
              /\ last' = [run |-> m.run, consumer |-> "workflow", outcome |-> "failed"]
    /\ UNCHANGED <<created, ns, agents, restarts>>

\* libfx's route takes a recovery message. With AckBare it acknowledges a
\* message with no prompt at once. Without it the route looks for the agent
\* the message names, "default", whose delivery ignores a message with no
\* prompt; a process with no agent of that name refuses it, and the World
\* delivers it again until MaxAttempts.
LibfxTakes(m) ==
    /\ ConsumerOf(m.topic) = "libfx"
    /\ IF AckBare \/ agents = "default"
         THEN /\ queue' = queue \ {m}
              /\ last' = [run |-> m.run, consumer |-> "libfx", outcome |-> "acked"]
         ELSE IF m.attempts + 1 < MaxAttempts
           THEN /\ queue' = (queue \ {m}) \cup {[m EXCEPT !.attempts = @ + 1]}
                /\ last' = [run |-> m.run, consumer |-> "libfx", outcome |-> "refused"]
           ELSE /\ queue' = queue \ {m}
                /\ last' = [run |-> m.run, consumer |-> "libfx", outcome |-> "dropped"]
    /\ UNCHANGED <<created, ns, status, agents, restarts>>

Deliver(m) == WorkflowTakes(m) \/ LibfxTakes(m)

\* A turn of a libfx session: it runs while the session's run is running,
\* and fails once the World has failed the run, which refuses its writes.
Turn(r) ==
    /\ r \in created \cap LibfxRuns
    /\ last' = [run |-> r, consumer |-> "turn", outcome |-> IF status[r] = "running" THEN "ran" ELSE "failed"]
    /\ UNCHANGED <<created, ns, status, agents, queue, restarts>>

Next ==
    \/ \E r \in Runs : Create(r)
    \/ \E a \in AgentSets, recover \in BOOLEAN : Restart(a, recover)
    \/ \E m \in queue : Deliver(m)
    \/ \E r \in LibfxRuns : Turn(r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* No restart fails a session this libfx created, and none fails its turns.
LibfxRunsNotFailed ==
    /\ \A r \in LibfxRuns : status[r] # "failed"
    /\ ~(last.consumer = "turn" /\ last.outcome = "failed")

\* Every recovery message goes to the consumer that owns its run.
RecoveryReachesOwner == \A m \in queue : ConsumerOf(m.topic) = Kind(m.run)

\* A consumer takes each recovery message at its first delivery.
RecoveryAckedFirstTime == last.outcome \notin {"refused", "dropped"}

\* The app's own runs still reach the Workflow SDK, which runs them.
AppRunsRun == \A r \in AppRuns : status[r] # "failed"
=============================================================================
