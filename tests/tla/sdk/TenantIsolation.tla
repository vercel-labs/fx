--------------------------- MODULE TenantIsolation ---------------------------
(***************************************************************************)
(* Tenants whose durable agents share one process, such as one Vercel      *)
(* Fluid function: what a turn may run, on whose agent, in which store,    *)
(* and with whose context.                                                 *)
(*                                                                         *)
(* Each tenant's app creates one agent, with a name, on a durability. The  *)
(* durability has a store key, which libfx reads off it (the `store` of    *)
(* world(), or its name), and a store, where its sessions are written.     *)
(* Two tenants can collide on a name and a key while their stores differ,  *)
(* as two world() Worlds both named "world" do. The app prompts only its   *)
(* own tenant's session. Every queued message reaches one route,           *)
(* wakeHandler(), which hands it to an agent in the process. An attacker   *)
(* can post any delivery to that route: a message id no app sent, or one   *)
(* it did, with any session, agent name, store key and context.            *)
(*                                                                         *)
(* Four rules keep tenants apart. Each constant turns one on:              *)
(*                                                                         *)
(* - LogFirst: a prompt's input, with its caller's context, reaches the    *)
(*   session's log before its message is queued, and the message only      *)
(*   names it. A delivery runs only what the log holds, so one the log     *)
(*   does not hold is refused (Witness-TrustBody).                         *)
(* - RouteByStore: a delivery goes only to an agent on the store key its   *)
(*   message names, never to one on another store that has the same name   *)
(*   (Witness-RouteByName).                                                *)
(* - OneDefinition: libfx refuses to create a second agent with a name a   *)
(*   different agent already has on the same store key, so one name on     *)
(*   one store is one agent (Witness-ShareName).                           *)
(* - Admission: an input over the size limit is refused before anything    *)
(*   is stored (Witness-NoAdmission).                                      *)
(*                                                                         *)
(* With all four off, the spec is libfx before them (Witness-Today).       *)
(*                                                                         *)
(* Development is a process where NODE_ENV is "development", whose dev     *)
(* server loads a module again and so creates its agent again. There, with *)
(* OneDefinition, a new agent of a name and store key replaces the agent   *)
(* it would be refused for. The replaced agent takes no more deliveries    *)
(* but still sends, since a module loaded before still holds it, and its   *)
(* inputs run on its replacement: RunsOnSenderOrReplacement holds, and     *)
(* RunsOnSenderAgent does not (Witness-DevReplaces). That needs one store  *)
(* key to be one store, as it is for a module that creates its World again *)
(* over the same storage. A replacement on another store under the same    *)
(* key leaves the replaced agent's inputs unrun (Witness-DevOtherStore).   *)
(*                                                                         *)
(* With LateStore, an app may create its agent without a durability, on    *)
(* the factory's default store, whose key libfx learns only when the agent *)
(* is first used (Resolve). Agents on the default share it, so two of one  *)
(* name collide when the second is created; an agent created on that store *)
(* with a durability collides with one on the default only once it         *)
(* resolves. In development the newest definition keeps the name either    *)
(* way (NewestWins): an older agent that resolves after a newer one took   *)
(* its store gives way to it, so every replacement is by a newer agent     *)
(* (ReplacedByNewer, Witness-DevOldestWins). A first use or a delivery     *)
(* resolves an agent before it reaches it, so here a delivery or a prompt  *)
(* waits for that agent's Resolve step.                                    *)
(*                                                                         *)
(* A worker that takes a message runs every input of the session its       *)
(* store holds and no turn ran yet, as one turn each. A session belongs to *)
(* the agent its first stored input names; a message that reached another  *)
(* agent is sent on to that one, as AgentRouting.tla checks.               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Topology,       \* which tenants share the process: "four", "shared" or "split"
    MaxPrompts,     \* prompts the apps send in all
    MaxForges,      \* deliveries the attacker posts in all
    LogFirst,
    RouteByStore,
    OneDefinition,
    Admission,
    Development,    \* a development server: a new definition replaces the old
    LateStore,      \* apps may create agents on the default store, learned on first use
    NewestWins      \* in development, an agent that resolves late gives way to a newer one

None == "none"
Forger == "forger"

\* "four": acme and evil collide on a name and a store key with different
\* stores; bob shares acme's store under another name; carl has acme's name
\* on another store key. "shared": two tenants on one store, one name, as
\* two agents created without a name or a durability are. "split": one name
\* on two store keys.
Tenants ==
    CASE Topology = "four" -> {"acme", "evil", "bob", "carl"}
      [] Topology = "shared" -> {"acme", "evil"}
      [] Topology = "split" -> {"acme", "carl"}
NameOf == [t \in Tenants |-> IF t = "bob" THEN "billing" ELSE "support"]
KeyOf == [t \in Tenants |-> IF t = "carl" THEN "k2" ELSE "k1"]
StoreOf == [t \in Tenants |->
    CASE t = "acme" -> "A"
      [] t = "evil" -> IF Topology = "shared" THEN "A" ELSE "B"
      [] t = "bob" -> "A"
      [] t = "carl" -> "C"]

Names == {NameOf[t] : t \in Tenants}
Keys == {KeyOf[t] : t \in Tenants}
Stores == {StoreOf[t] : t \in Tenants}
\* Id 0 is one no app ever sends.
Ids == 0..MaxPrompts
Contexts == Tenants \cup {Forger, None}
Sizes == {"ok", "big", None}

Msg == [id: Ids, s: Tenants, n: Names, key: Keys, ctx: Contexts, size: Sizes]
Entry == [id: Ids, s: Tenants, n: Names, ctx: Contexts, size: Sizes]
Turn == [id: Ids, def: Tenants, store: Stores, ctx: Contexts]

VARIABLES
    agents,   \* tenants whose agent runs in the process
    refused,  \* tenants whose agent libfx refused to create
    log,      \* the inputs each store holds
    owner,    \* the agent each session belongs to, in each store
    done,     \* the inputs whose turn ran, in each store
    queue,    \* messages queued and not yet taken
    ran,      \* turns run: which input, on whose agent, in which store, with which context
    sent,     \* the prompts the apps sent, by id and tenant
    forges,   \* deliveries the attacker posted so far
    replacedBy, \* in development, the tenant whose agent replaced each one's
    defaulted,  \* tenants whose agent was created on the default store
    unresolved, \* agents on the default store whose store key libfx has not learned
    born,       \* in development, the order the agents were created in; 0 for none
    act       \* the step just taken, for the driver

vars == <<agents, refused, log, owner, done, queue, ran, sent, forges, replacedBy, defaulted, unresolved, born, act>>

\* Tenants whose agent another replaced: they still send.
Replaced == {t \in Tenants: replacedBy[t] # None}

TypeOK ==
    /\ agents \subseteq Tenants
    /\ refused \subseteq Tenants
    /\ replacedBy \in [Tenants -> Tenants \cup {None}]
    /\ defaulted \subseteq Tenants
    /\ unresolved \subseteq agents \cap defaulted
    /\ born \in [Tenants -> 0..Cardinality(Tenants)]
    /\ log \in [Stores -> SUBSET Entry]
    /\ owner \in [Stores -> [Tenants -> Names \cup {None}]]
    /\ done \in [Stores -> SUBSET Ids]
    /\ queue \subseteq Msg
    /\ ran \subseteq Turn
    /\ sent \subseteq [id: Ids, t: Tenants]
    /\ forges \in 0..MaxForges

Init ==
    /\ agents = {}
    /\ refused = {}
    /\ log = [st \in Stores |-> {}]
    /\ owner = [st \in Stores |-> [s \in Tenants |-> None]]
    /\ done = [st \in Stores |-> {}]
    /\ queue = {}
    /\ ran = {}
    /\ sent = {}
    /\ forges = 0
    /\ replacedBy = [t \in Tenants |-> None]
    /\ defaulted = {}
    /\ unresolved = {}
    /\ born = [t \in Tenants |-> 0]
    /\ act = [name |-> "Init"]

\* What the queue carries for m: with LogFirst, only which input it names.
Ref(m) == IF LogFirst THEN [m EXCEPT !.ctx = None, !.size = None] ELSE m

\* Tenant t's app creates its agent: on its durability, or, when `late`, on
\* the default store, whose key libfx learns on first use. Agents on the
\* default collide with one another at once, and with agents on a store of
\* their own only once they resolve. In development, an agent OneDefinition
\* would refuse replaces the agents it collides with instead.
Register(t, late) ==
    LET rivals == IF late
                  THEN {u \in agents \cap defaulted: NameOf[u] = NameOf[t]}
                  ELSE {u \in agents \ unresolved: NameOf[u] = NameOf[t] /\ KeyOf[u] = KeyOf[t]}
        mine == IF late THEN {t} ELSE {}
    IN
    /\ late => LateStore
    /\ t \notin agents \cup refused \cup Replaced
    /\ IF OneDefinition /\ rivals # {}
       THEN IF Development
            THEN /\ agents' = (agents \ rivals) \cup {t}
                 /\ replacedBy' = [u \in Tenants |-> IF u \in rivals THEN t ELSE replacedBy[u]]
                 /\ unresolved' = (unresolved \ rivals) \cup mine
                 /\ defaulted' = defaulted \cup mine
                 /\ UNCHANGED refused
            ELSE /\ refused' = refused \cup {t}
                 /\ UNCHANGED <<agents, replacedBy, unresolved, defaulted>>
       ELSE /\ agents' = agents \cup {t}
            /\ unresolved' = unresolved \cup mine
            /\ defaulted' = defaulted \cup mine
            /\ UNCHANGED <<refused, replacedBy>>
    /\ born' = IF Development THEN [born EXCEPT ![t] = Cardinality({u \in Tenants: born[u] > 0}) + 1] ELSE born
    /\ act' = [name |-> "Register", t |-> t, late |-> late]
    /\ UNCHANGED <<log, owner, done, queue, ran, sent, forges>>

\* Agent t, created on the default store, is first used, and libfx learns
\* its store key. An agent of its name created on that key with a durability
\* collides with it now. In development the newest of them keeps the name:
\* with NewestWins, t gives way to a newer one, and otherwise replaces it, as
\* libfx did before; outside development t's first use fails, and it leaves
\* the name.
Resolve(t) ==
    LET rivals == {u \in agents \ unresolved: u # t /\ NameOf[u] = NameOf[t] /\ KeyOf[u] = KeyOf[t]}
        newer == {u \in rivals: born[u] > born[t]}
    IN
    /\ t \in unresolved
    /\ unresolved' = unresolved \ {t}
    /\ IF OneDefinition /\ rivals # {}
       THEN IF Development
            THEN /\ IF NewestWins /\ newer # {}
                    THEN /\ agents' = agents \ {t}
                         /\ replacedBy' = [replacedBy EXCEPT ![t] = CHOOSE n \in newer: \A u \in newer: born[u] <= born[n]]
                    ELSE /\ agents' = agents \ rivals
                         /\ replacedBy' = [u \in Tenants |-> IF u \in rivals THEN t ELSE replacedBy[u]]
                 /\ UNCHANGED refused
            ELSE /\ agents' = agents \ {t}
                 /\ refused' = refused \cup {t}
                 /\ UNCHANGED replacedBy
       ELSE UNCHANGED <<agents, refused, replacedBy>>
    /\ act' = [name |-> "Resolve", t |-> t]
    /\ UNCHANGED <<log, owner, done, queue, ran, sent, forges, defaulted, born>>

\* Tenant t's app sends an input of `size` to its own session, through its
\* agent, which may have been replaced since.
Send(t, size) ==
    LET id == Cardinality(sent) + 1
        st == StoreOf[t]
        m == [id |-> id, s |-> t, n |-> NameOf[t], key |-> KeyOf[t], ctx |-> t, size |-> size]
    IN
    /\ t \in (agents \ unresolved) \cup Replaced
    /\ Cardinality(sent) < MaxPrompts
    /\ sent' = sent \cup {[id |-> id, t |-> t]}
    /\ queue' = queue \cup {Ref(m)}
    /\ IF LogFirst
       THEN /\ log' = [log EXCEPT ![st] = @ \cup {[id |-> id, s |-> t, n |-> NameOf[t], ctx |-> t, size |-> size]}]
            /\ owner' = [owner EXCEPT ![st][t] = IF @ = None THEN NameOf[t] ELSE @]
       ELSE UNCHANGED <<log, owner>>
    /\ UNCHANGED <<agents, refused, done, ran, forges, replacedBy, defaulted, unresolved, born>>

Prompt(t) ==
    /\ Send(t, "ok")
    /\ act' = [name |-> "Prompt", t |-> t, id |-> Cardinality(sent) + 1]

\* The app sends an input over the limit, as a prompt or a steer.
Oversize(t, k) ==
    /\ t \in agents \cup Replaced
    /\ IF Admission
       THEN UNCHANGED <<agents, refused, log, owner, done, queue, ran, sent, forges, replacedBy, defaulted, unresolved, born>>
       ELSE Send(t, "big")
    /\ act' = [name |-> "Oversize", t |-> t, k |-> k]

\* The agents in the process a delivery of m can reach.
Candidates(m) == {a \in agents: NameOf[a] = m.n /\ (RouteByStore => KeyOf[a] = m.key)}

\* Whether every agent of the name m names knows its store, as it does by
\* the time a delivery of m reaches it.
ResolvedFor(m) == \A a \in unresolved: NameOf[a] # m.n

\* Agent a's worker takes m; `rest` is the queue without it.
Take(m, a, rest) ==
    LET st == StoreOf[a]
        held == {x \in log[st]: x.id = m.id /\ x.s = m.s}
        own == IF owner[st][m.s] = None THEN m.n ELSE owner[st][m.s]
        body == [id |-> m.id, s |-> m.s, n |-> m.n, ctx |-> m.ctx, size |-> m.size]
        logged == IF held = {} THEN log[st] \cup {body} ELSE log[st]
        pend == {x \in logged: x.s = m.s /\ x.id \notin done[st]}
    IN
    IF LogFirst /\ held = {}
    THEN \* The log does not hold it: refused, and nothing is written.
         /\ queue' = rest
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE IF own # NameOf[a]
    THEN \* Another agent's session: sent on to it.
         /\ queue' = rest \cup {Ref([m EXCEPT !.n = own])}
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE /\ log' = [log EXCEPT ![st] = logged]
         /\ owner' = [owner EXCEPT ![st][m.s] = own]
         /\ ran' = ran \cup {[id |-> x.id, def |-> a, store |-> st, ctx |-> x.ctx] : x \in pend}
         /\ done' = [done EXCEPT ![st] = @ \cup {x.id : x \in pend}]
         /\ queue' = rest

\* A delivery of m reaches the route. With no agent to take it, the queue
\* keeps `missed` as it was.
Handle(m, rest, missed) ==
    IF Candidates(m) = {}
    THEN /\ queue' = missed
         /\ UNCHANGED <<log, owner, done, ran>>
    ELSE \E a \in Candidates(m): Take(m, a, rest)

\* The queue delivers a message to the route.
Deliver(m) ==
    /\ m \in queue
    /\ ResolvedFor(m)
    /\ Handle(m, queue \ {m}, queue)
    /\ act' = [name |-> "Deliver", id |-> m.id, s |-> m.s, n |-> m.n, key |-> m.key]
    /\ UNCHANGED <<agents, refused, sent, forges, replacedBy, defaulted, unresolved, born>>

\* The attacker posts a delivery straight to the route.
Forge(id, s, n, key) ==
    /\ forges < MaxForges
    /\ id \in {0} \cup {x.id : x \in sent}
    /\ ResolvedFor([n |-> n])
    /\ Handle([id |-> id, s |-> s, n |-> n, key |-> key, ctx |-> Forger, size |-> "ok"], queue, queue)
    /\ forges' = forges + 1
    /\ act' = [name |-> "Forge", id |-> id, s |-> s, n |-> n, key |-> key]
    /\ UNCHANGED <<agents, refused, sent, replacedBy, defaulted, unresolved, born>>

Next ==
    \/ \E t \in Tenants, late \in BOOLEAN: Register(t, late)
    \/ \E t \in unresolved: Resolve(t)
    \/ \E t \in Tenants: Prompt(t)
    \/ \E t \in Tenants, k \in {"prompt", "steer"}: Oversize(t, k)
    \/ \E m \in queue: Deliver(m)
    \/ \E id \in Ids, s \in Tenants, n \in Names, key \in Keys: Forge(id, s, n, key)

Spec == Init /\ [][Next]_vars

\* The queue keeps delivering each message some agent can take, and an
\* agent on the default store is used, and so resolved, before long.
FairSpec == Spec /\ WF_vars(\E m \in queue: Candidates(m) # {} /\ Deliver(m)) /\ WF_vars(\E t \in unresolved: Resolve(t))

-----------------------------------------------------------------------------
(* Properties *)

Sender(r) == {x \in sent: x.id = r.id}

\* Only an input an app sent runs.
OnlySentRuns == \A r \in ran: Sender(r) # {}

\* It runs on its own tenant's agent, in its tenant's store, with the
\* context its app gave.
RunsOnSenderAgent == \A r \in ran: \A x \in Sender(r): r.def = x.t
RunsInSenderStore == \A r \in ran: \A x \in Sender(r): r.store = StoreOf[x.t]

\* Tenant t and the tenants whose agents replaced its own, directly or in turn.
Successors(t) ==
    LET Reach[n \in 0..Cardinality(Tenants)] ==
            IF n = 0 THEN {t}
            ELSE Reach[n - 1] \cup {replacedBy[u] : u \in {v \in Reach[n - 1]: replacedBy[v] # None}}
    IN Reach[Cardinality(Tenants)]

\* In development, an input runs on its sender's agent or on one that
\* replaced it; without Development this is RunsOnSenderAgent.
RunsOnSenderOrReplacement == \A r \in ran: \A x \in Sender(r): r.def \in Successors(x.t)
RunsWithSenderContext == \A r \in ran: \A x \in Sender(r): r.ctx = x.t

\* In development, a chain of replacements ends at the newest agent: every
\* agent that replaced another was created after it.
ReplacedByNewer == \A t \in Tenants: replacedBy[t] # None => born[replacedBy[t]] > born[t]

\* No store holds an input over the limit.
StoredWithinLimit == \A st \in Stores: \A e \in log[st]: e.size # "big"

\* Every prompt an app sent runs.
SentRuns == \A i \in 1..MaxPrompts: []((\E x \in sent: x.id = i) => <>(\E r \in ran: r.id = i))
=============================================================================
