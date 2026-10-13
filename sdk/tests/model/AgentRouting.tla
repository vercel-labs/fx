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
(* An input is stored by the sender before it queues the message on a      *)
(* queue that ends with the process (memory, local: RecordAtSend), and by  *)
(* the worker that takes it on one that keeps messages (Vercel).           *)
(*                                                                         *)
(* With ByName = FALSE a process hands each delivery to any of its agents, *)
(* as libfx did before names (Witness-NoNames). With CheckOwner = FALSE a  *)
(* worker runs any session it is handed, so a prompt sent to another       *)
(* agent's session runs on the sender (Witness-NoOwnerCheck).              *)
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
    RecordAtSend,  \* the sender stores a prompt's input before it queues it
    ByName,        \* a delivery goes to the agent the message names
    CheckOwner     \* a worker runs only its own agent's sessions

None == "none"
Hosts == [p \in Procs |-> IF p = "p2" THEN Names \ {P2Lacks} ELSE Names]

VARIABLES
    queue,   \* messages queued and not yet taken: [id, s, n]
    owner,   \* the agent each session belongs to, once an input is stored
    ran,     \* <<session, agent>>: an agent ran one of the session's turns
    missed,  \* names a delivery found no agent for
    sends,   \* prompts sent so far, which also numbers them
    act      \* the step just taken, for the driver

vars == <<queue, owner, ran, missed, sends, act>>

Msg == [id: 0..MaxSends, s: Sessions, n: Names]

TypeOK ==
    /\ queue \subseteq Msg
    /\ owner \in [Sessions -> Names \cup {None}]
    /\ ran \subseteq (Sessions \X Names)
    /\ missed \subseteq Names
    /\ sends \in 0..MaxSends

Init ==
    /\ queue = {}
    /\ owner = [s \in Sessions |-> None]
    /\ ran = {}
    /\ missed = {}
    /\ sends = 0
    /\ act = [name |-> "Init"]

\* A session's owner once an input naming n is stored: the first one stays.
Stored(o, n) == IF o = None THEN n ELSE o

\* Agent n prompts session s: its message names n.
Send(n, s) ==
    /\ sends < MaxSends
    /\ queue' = queue \cup {[id |-> sends, s |-> s, n |-> n]}
    /\ sends' = sends + 1
    /\ owner' = IF RecordAtSend THEN [owner EXCEPT ![s] = Stored(@, n)] ELSE owner
    /\ act' = [name |-> "Send", n |-> n, s |-> s, id |-> sends]
    /\ UNCHANGED <<ran, missed>>

\* The queue delivers m to process p. The agent a that takes it stores the
\* input, then runs the turn or sends the message on to the session's owner.
Deliver(p, m) ==
    /\ m \in queue
    /\ act' = [name |-> "Deliver", p |-> p, id |-> m.id]
    /\ IF ByName /\ m.n \notin Hosts[p]
       THEN /\ missed' = missed \cup {m.n}
            /\ UNCHANGED <<queue, owner, ran, sends>>
       ELSE \E a \in (IF ByName THEN {m.n} ELSE Hosts[p]):
                LET o == Stored(owner[m.s], m.n) IN
                /\ owner' = [owner EXCEPT ![m.s] = o]
                /\ IF CheckOwner /\ o # a
                   THEN /\ queue' = (queue \ {m}) \cup {[m EXCEPT !.n = o]}
                        /\ UNCHANGED ran
                   ELSE /\ queue' = queue \ {m}
                        /\ ran' = ran \cup {<<m.s, a>>}
                /\ UNCHANGED <<missed, sends>>

Next ==
    \/ \E n \in Names, s \in Sessions: Send(n, s)
    \/ \E p \in Procs, m \in queue: Deliver(p, m)

Spec == Init /\ [][Next]_vars

\* The queue keeps delivering each message, and not only to processes
\* without its agent: one that has it gets it eventually.
FairSpec == Spec /\ SF_vars(\E p \in Procs, m \in queue: m.n \in Hosts[p] /\ Deliver(p, m))

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
Drains == <>[](queue = {})
=============================================================================
