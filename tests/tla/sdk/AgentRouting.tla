----------------------------- MODULE AgentRouting -----------------------------
(***************************************************************************)
(* Which agent runs a durable session's turns when an app has several.     *)
(*                                                                         *)
(* Every agent queues its turns on one topic. A queued message names the   *)
(* agent that sent it. The queue delivers a message to a process, which    *)
(* hands it to its agent of that name; a process with no such agent fails  *)
(* the delivery, naming the agent, and the queue keeps the message to      *)
(* deliver again. The agent's worker stores the message's input, which     *)
(* names the sender, and runs the turn when the session is its own. A      *)
(* session belongs to the agent its first stored input names, so a prompt  *)
(* one agent sends to another agent's session is sent on to that agent.    *)
(*                                                                         *)
(* The sender stores an input before it queues the message, on every      *)
(* queue, so a session has its owner from its first send on. A message     *)
(* only names the input (TenantIsolation.tla LogFirst).                    *)
(*                                                                         *)
(* With ByName = FALSE a process hands each delivery to any of its agents, *)
(* as libfx did before names (Witness-NoNames). With CheckOwner = FALSE a  *)
(* worker runs any session it is handed, so a prompt sent to another       *)
(* agent's session runs on the sender (Witness-NoOwnerCheck).              *)
(*                                                                         *)
(* A queue that ends with its process loses the messages a process holds   *)
(* when it dies, up to MaxCrashes times, while the inputs they name stay   *)
(* stored: the session keeps work no message delivers. With Recovery, an   *)
(* agent that starts in a process queues a recovery naming itself for each *)
(* session of its name with such work and no message on its way. Like any *)
(* message it names an input the session already stored, so a worker      *)
(* runs it as any other (TenantIsolation.tla OnlySentRuns). A later crash  *)
(* can lose it too; delivered, it runs the session's work. Without it the  *)
(* work waits forever (Witness-NoRecovery).                                *)
(*                                                                         *)
(* A turn here is one step: what this spec checks is which agent runs it.  *)
(* DurableSession.tla checks what happens within one agent's session.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,         \* the agents' names
    Sessions,
    Procs,         \* processes the queue delivers to; each has an agent of every name but P2Lacks
    P2Lacks,       \* a name process "p2" has no agent for, or "none"
    MaxSends,      \* prompts sent in all
    ByName,        \* a delivery goes to the agent the message names
    CheckOwner,    \* a worker runs only its own agent's sessions
    MaxCrashes,    \* times a process dies with the messages it holds
    Recovery       \* an agent that starts runs the inputs crashes left

None == "none"
Hosts == [p \in Procs |-> IF p = "p2" THEN Names \ {P2Lacks} ELSE Names]

VARIABLES
    queue,       \* messages queued and not yet taken: [id, s, n]
    owner,       \* the agent each session belongs to, once an input is stored
    ran,         \* <<session, agent>>: an agent ran one of the session's turns
    missed,      \* names a delivery found no agent for
    sends,       \* prompts sent so far, which also numbers them
    stored,      \* the inputs each session stored and has not run, by message id,
                 \* kept where a crash can lose their messages
    recovering,  \* recoveries queued and not yet taken: [s, n]
    crashes,     \* processes that died so far
    act          \* the step just taken, for the driver

vars == <<queue, owner, ran, missed, sends, stored, recovering, crashes, act>>

Msg == [id: 0..MaxSends, s: Sessions, n: Names]

TypeOK ==
    /\ queue \subseteq Msg
    /\ owner \in [Sessions -> Names \cup {None}]
    /\ ran \subseteq (Sessions \X Names)
    /\ missed \subseteq Names
    /\ sends \in 0..MaxSends
    /\ stored \in [Sessions -> SUBSET (0..MaxSends)]
    /\ recovering \subseteq [s: Sessions, n: Names]
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ queue = {}
    /\ owner = [s \in Sessions |-> None]
    /\ ran = {}
    /\ missed = {}
    /\ sends = 0
    /\ stored = [s \in Sessions |-> {}]
    /\ recovering = {}
    /\ crashes = 0
    /\ act = [name |-> "Init"]

\* A session's owner once an input naming n is stored: the first one stays.
Stored(o, n) == IF o = None THEN n ELSE o

\* Whether a crash can lose the message of an input the sender stored, so
\* the model tracks the inputs no run took.
Tracked == MaxCrashes > 0

\* Agent n prompts session s: its message names n.
Send(n, s) ==
    /\ sends < MaxSends
    /\ queue' = queue \cup {[id |-> sends, s |-> s, n |-> n]}
    /\ sends' = sends + 1
    /\ owner' = [owner EXCEPT ![s] = Stored(@, n)]
    /\ stored' = IF Tracked THEN [stored EXCEPT ![s] = @ \cup {sends}] ELSE stored
    /\ act' = [name |-> "Send", n |-> n, s |-> s, id |-> sends]
    /\ UNCHANGED <<ran, missed, recovering, crashes>>

\* The queue delivers m to process p. The agent a that takes it runs the
\* turn, or sends the message on to the session's owner. A run takes every
\* input the session stored, one whose message is gone too.
Deliver(p, m) ==
    /\ m \in queue
    /\ act' = [name |-> "Deliver", p |-> p, id |-> m.id]
    /\ IF ByName /\ m.n \notin Hosts[p]
       THEN /\ missed' = missed \cup {m.n}
            /\ UNCHANGED <<queue, owner, ran, sends, stored>>
       ELSE \E a \in (IF ByName THEN {m.n} ELSE Hosts[p]):
                LET o == Stored(owner[m.s], m.n) IN
                /\ owner' = [owner EXCEPT ![m.s] = o]
                /\ IF CheckOwner /\ o # a
                   THEN /\ queue' = (queue \ {m}) \cup {[m EXCEPT !.n = o]}
                        /\ UNCHANGED <<ran, stored>>
                   ELSE /\ queue' = queue \ {m}
                        /\ ran' = ran \cup {<<m.s, a>>}
                        /\ stored' = [stored EXCEPT ![m.s] = {}]
                /\ UNCHANGED <<missed, sends>>
    /\ UNCHANGED <<recovering, crashes>>

\* A process dies holding m, which its queue loses, as a queue that ends
\* with its process does. The input m names stays stored, unless a run
\* took it already.
Crash(m) ==
    /\ crashes < MaxCrashes
    /\ m \in queue
    /\ queue' = queue \ {m}
    /\ crashes' = crashes + 1
    /\ act' = [name |-> "Crash", id |-> m.id]
    /\ UNCHANGED <<owner, ran, missed, sends, stored, recovering>>

\* A process dies holding recovery r; its session's inputs stay stored.
CrashRecovery(r) ==
    /\ crashes < MaxCrashes
    /\ r \in recovering
    /\ recovering' = recovering \ {r}
    /\ crashes' = crashes + 1
    /\ act' = [name |-> "CrashRecovery", s |-> r.s]
    /\ UNCHANGED <<queue, owner, ran, missed, sends, stored>>

\* The sessions agent n finds as it starts: its own, with inputs stored and
\* no message queued for them. The code finds those whose last writer died,
\* and a writer that still runs holds a message for the session.
Found(n) == {s \in Sessions : owner[s] = n /\ stored[s] # {} /\ \A m \in queue : m.s # s}

\* Agent n starts in process p and queues a recovery naming itself for each
\* session it finds: a message naming one of the session's stored inputs.
Recover(p, n) ==
    /\ Recovery
    /\ n \in Hosts[p]
    /\ Found(n) # {}
    /\ recovering' = recovering \cup {[s |-> s, n |-> n] : s \in Found(n)}
    /\ act' = [name |-> "Recover", p |-> p, n |-> n]
    /\ UNCHANGED <<queue, owner, ran, missed, sends, stored, crashes>>

\* The queue delivers recovery r to process p. Its agent of r.n runs the
\* session's work, or sends the recovery on to the session's owner, as it
\* does a prompt; a process without one fails the delivery, and the queue
\* keeps it.
DeliverRecovery(p, r) ==
    /\ r \in recovering
    /\ act' = [name |-> "DeliverRecovery", p |-> p, s |-> r.s]
    /\ IF r.n \notin Hosts[p]
       THEN /\ missed' = missed \cup {r.n}
            /\ UNCHANGED <<recovering, ran, stored>>
       ELSE IF CheckOwner /\ owner[r.s] # r.n
       THEN /\ recovering' = (recovering \ {r}) \cup {[r EXCEPT !.n = owner[r.s]]}
            /\ UNCHANGED <<ran, stored, missed>>
       ELSE /\ recovering' = recovering \ {r}
            /\ ran' = ran \cup {<<r.s, r.n>>}
            /\ stored' = [stored EXCEPT ![r.s] = {}]
            /\ UNCHANGED missed
    /\ UNCHANGED <<queue, owner, sends, crashes>>

Next ==
    \/ \E n \in Names, s \in Sessions: Send(n, s)
    \/ \E p \in Procs, m \in queue: Deliver(p, m)
    \/ \E m \in queue: Crash(m)
    \/ \E r \in recovering: CrashRecovery(r)
    \/ \E p \in Procs, n \in Names: Recover(p, n)
    \/ \E p \in Procs, r \in recovering: DeliverRecovery(p, r)

Spec == Init /\ [][Next]_vars

\* The queue keeps delivering each message, and not only to processes
\* without its agent: one that has it gets it eventually. An agent of each
\* name starts eventually.
FairSpec ==
    /\ Spec
    /\ SF_vars(\E p \in Procs, m \in queue: m.n \in Hosts[p] /\ Deliver(p, m))
    /\ SF_vars(\E p \in Procs, r \in recovering: r.n \in Hosts[p] /\ DeliverRecovery(p, r))
    /\ WF_vars(\E p \in Procs, n \in Names: Recover(p, n))

-----------------------------------------------------------------------------
(* Properties *)

\* Every turn of a session runs on the agent the session belongs to.
RunsOnOwner == \A r \in ran: r[2] = owner[r[1]]

\* A delivery finds no agent only in a process that lacks that name.
MissOnlyWhereLacking == \A n \in missed: \E p \in Procs: n \notin Hosts[p]

\* A session's owner never changes once set.
OwnerKept == [][\A s \in Sessions: owner[s] # None => owner'[s] = owner[s]]_vars

\* Every queued message is eventually taken, so no prompt is lost, even when
\* a process lacks its agent.
Drains == <>[](queue = {} /\ recovering = {})

\* Every stored input runs eventually, one whose message a crash lost too, on
\* its session's own agent (RunsOnOwner).
Recovered == <>[](\A s \in Sessions : stored[s] = {})
=============================================================================
