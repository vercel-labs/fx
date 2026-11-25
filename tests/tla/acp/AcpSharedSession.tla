------------------------- MODULE AcpSharedSession -------------------------
(***************************************************************************)
(* The clients of one shared session in the sh.fx extension to ACP: the    *)
(* "Prompts from other clients", "Permission requests", "Stopping a turn", *)
(* and "Who is connected" parts of "Following a session" in                *)
(* src/protocol/spec/sh-fx.md. The prompt, stop, permission, and client-list  *)
(* parts are built in src/acp/. AcpApprovals.tla models the permission part, *)
(* and tests/tla/drivers/acp/shared_session checks the client-list part on    *)
(* the built fx.                                                              *)
(*                                                                         *)
(* One session, a few connections that open and close it. fx writes each  *)
(* connection's messages in order, and the client reads them later (Read): *)
(* a permission request, its cancellation, another client's prompt or      *)
(* steer, its answer to opening the session, or the list of connected      *)
(* clients.                                                                *)
(*                                                                         *)
(* Rules (Rules = TRUE):                                                   *)
(*  - fx sends a prompt that starts a turn to every other client that has *)
(*    the session open, and never back to its sender. A steer goes to      *)
(*    every client that has the session open, the sender included.         *)
(*  - fx sends a permission request to every client that has the session  *)
(*    open, and to one that opens it while the request waits. The first   *)
(*    answer decides; fx cancels the request on the others and ignores    *)
(*    later answers. session/cancel cancels a waiting request too.        *)
(*  - Any client that has the session open can stop the running turn.     *)
(*  - fx sends the list of connected clients to each client that lists     *)
(*    sh.fx/sessionClients, after a client opens or closes the session.    *)
(*    The list names every client that has the session open, and the main  *)
(*    client, the first one that opened it. A list is never sent when no    *)
(*    client has the session open.                                          *)
(*  - A client that opens the session with session/load or resume gets its  *)
(*    list before its answer, and the list includes the client itself. A    *)
(*    client that opens it with session/new gets the list after its answer.  *)
(*  - A prompt or steer chunk that fx sends to a client that lists          *)
(*    sh.fx/sessionClients names its sender, as the chunk's sh.fx/client.   *)
(*    A client that does not list it gets the chunk without the sender.     *)
(*                                                                         *)
(* Today (Rules = FALSE): the rules are off, so fx acts as if only the     *)
(* prompt's sender were there: no client sees another's prompt             *)
(* or the list of clients, and only the sender's session/cancel stops the   *)
(* turn. For permission requests, Today is design "current" of               *)
(* AcpApprovals.tla, where the question goes to the main client only.        *)
(*                                                                         *)
(* Simplifications: a session/new opener is the first client of a session  *)
(* that no client has open, so the model lets a new open happen whenever    *)
(* no client has the session open. Steers are not queued, and queued        *)
(* prompts are AcpPromptDelivery's. The main client is the first client in  *)
(* the order of opening, and a takeover moves it to the next client.        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,       \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Conns,       \* the client connections
    Lists,       \* the connections whose client lists sh.fx/sessionClients
    SenderKey,   \* TRUE: a chunk to a listing client names its sender as sh.fx/client
    MaxPrompts,  \* prompts and steers in the whole run
    MaxAsks      \* permission requests in the whole run

None == "none"
NoRoster == {None}   \* the client hasn't read a list of clients yet

VARIABLES
    open,          \* [Conns -> BOOLEAN]: the connection has the session open
    turn,          \* the connection whose prompt runs, or None
    perm,          \* the latest permission request: [id, decided]; id 0 is none
    applied,       \* answers fx applied to the latest request
    sentTo,        \* connections fx sent the latest request to that haven't answered or lost it
    shown,         \* [Conns -> Nat]: the request each client shows; 0 is none
    chan,          \* [Conns -> Seq(message)]: written by fx, not yet read
    prompts,       \* prompts and steers taken so far; prompt k has id k
    sentBy,        \* [1..MaxPrompts -> Conns \cup {None}]
    due,           \* [Conns -> SUBSET 1..MaxPrompts]: other clients' prompts taken while it had the session open
    got,           \* [Conns -> SUBSET 1..MaxPrompts]: prompts the client read
    roster,        \* [Conns -> SUBSET Conns, or NoRoster]: the list of clients it read last
    cancelIgnored, \* a session/cancel from a client with the session open didn't stop the turn
    order,         \* the connections that have the session open, in the order they opened it
    rmain,         \* [Conns -> Conns \cup {None}]: the main client the list it read last named
    answered,      \* [Conns -> BOOLEAN]: the client has read its answer to opening the session
    newOpened      \* [Conns -> BOOLEAN]: the client opened the session with session/new

vars == <<open, turn, perm, applied, sentTo, shown, chan, prompts, sentBy, due, got, roster,
          cancelIgnored, order, rmain, answered, newOpened>>

Req(p) == [kind |-> "req", n |-> p, who |-> {}, main |-> None]
CancelMsg(p) == [kind |-> "cancel", n |-> p, who |-> {}, main |-> None]
AnswerMsg == [kind |-> "answer", n |-> 0, who |-> {}, main |-> None]
Clients(set, m) == [kind |-> "clients", n |-> 0, who |-> set, main |-> m]

\* The sender a chunk names, for one client: the sender's id for a client that
\* lists sh.fx/sessionClients when the key is on, and None for any other.
SenderOf(s, d) == IF SenderKey /\ d \in Lists THEN s ELSE None
Echo(k, s, d) == [kind |-> "echo", n |-> k, who |-> {}, main |-> None, from |-> SenderOf(s, d)]
SteerMsg(k, s, d) == [kind |-> "steer", n |-> k, who |-> {}, main |-> None, from |-> SenderOf(s, d)]

Waiting == perm.id # 0 /\ ~perm.decided

Roster(now) == {d \in Conns : now[d]}

\* The list of clients a client gets when the session's open clients are `now`,
\* in the order `ord`. Only a client that lists sh.fx/sessionClients gets one.
RosterOut(d, now, ord) ==
    IF Rules /\ now[d] /\ d \in Lists THEN <<Clients(Roster(now), Head(ord))>> ELSE <<>>

Init ==
    /\ open = [c \in Conns |-> FALSE]
    /\ turn = None
    /\ perm = [id |-> 0, decided |-> TRUE]
    /\ applied = 0
    /\ sentTo = {}
    /\ shown = [c \in Conns |-> 0]
    /\ chan = [c \in Conns |-> <<>>]
    /\ prompts = 0
    /\ sentBy = [k \in 1..MaxPrompts |-> None]
    /\ due = [c \in Conns |-> {}]
    /\ got = [c \in Conns |-> {}]
    /\ roster = [c \in Conns |-> NoRoster]
    /\ cancelIgnored = FALSE
    /\ order = <<>>
    /\ rmain = [c \in Conns |-> None]
    /\ answered = [c \in Conns |-> FALSE]
    /\ newOpened = [c \in Conns |-> FALSE]

\* A client opens the session with session/new (k = "new") or with session/load
\* or resume (k = "load"). A waiting request goes to it first. A joiner gets the
\* list before its answer; a new opener gets its answer first, then the list.
OpenAs(c, k) ==
    /\ ~open[c]
    /\ (k = "load" \/ order = <<>>)
    /\ LET now == [open EXCEPT ![c] = TRUE]
           ordN == Append(order, c)
           ask == IF Rules /\ Waiting THEN <<Req(perm.id)>> ELSE <<>>
           mine == IF k = "new"
                   THEN <<AnswerMsg>> \o ask \o RosterOut(c, now, ordN)
                   ELSE ask \o RosterOut(c, now, ordN) \o <<AnswerMsg>>
       IN /\ open' = now
          /\ order' = ordN
          /\ chan' = [d \in Conns |-> IF d = c THEN chan[d] \o mine ELSE chan[d] \o RosterOut(d, now, ordN)]
          /\ newOpened' = [newOpened EXCEPT ![c] = (k = "new")]
          /\ sentTo' = IF Rules /\ Waiting THEN sentTo \cup {c} ELSE sentTo
    /\ UNCHANGED <<turn, perm, applied, shown, prompts, sentBy, due, got, roster,
                   cancelIgnored, rmain, answered>>

\* A client closes the session. Its response comes after every message fx
\* wrote before it, so the client acts on the close once it has read them.
\* fx drops the request it can no longer answer, and the turn goes on.
Close(c) ==
    /\ open[c] /\ chan[c] = <<>>
    /\ LET now == [open EXCEPT ![c] = FALSE]
           ordN == SelectSeq(order, LAMBDA x: x # c)
       IN /\ open' = now
          /\ order' = ordN
          /\ chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now, ordN)]
    /\ sentTo' = sentTo \ {c}
    /\ shown' = [shown EXCEPT ![c] = 0]
    /\ due' = [due EXCEPT ![c] = {}]
    /\ got' = [got EXCEPT ![c] = {}]
    /\ roster' = [roster EXCEPT ![c] = NoRoster]
    /\ rmain' = [rmain EXCEPT ![c] = None]
    /\ answered' = [answered EXCEPT ![c] = FALSE]
    /\ newOpened' = [newOpened EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<turn, perm, applied, prompts, sentBy, cancelIgnored>>

\* A client's prompt starts a turn, and goes to the other clients.
Prompt(c) ==
    /\ open[c] /\ turn = None /\ prompts < MaxPrompts
    /\ LET k == prompts + 1 IN
       /\ prompts' = k
       /\ sentBy' = [sentBy EXCEPT ![k] = c]
       /\ due' = [d \in Conns |-> IF open[d] /\ d # c THEN due[d] \cup {k} ELSE due[d]]
       /\ chan' = [d \in Conns |-> IF Rules /\ open[d] /\ d # c THEN Append(chan[d], Echo(k, c, d)) ELSE chan[d]]
    /\ turn' = c
    /\ UNCHANGED <<open, perm, applied, sentTo, shown, got, roster, cancelIgnored, order, rmain, answered, newOpened>>

\* A client's steer joins the running turn, and goes to every client that has
\* the session open, the sender included.
Steer(c) ==
    /\ open[c] /\ turn # None /\ prompts < MaxPrompts
    /\ LET k == prompts + 1 IN
       /\ prompts' = k
       /\ sentBy' = [sentBy EXCEPT ![k] = c]
       /\ due' = [d \in Conns |-> IF open[d] /\ d # c THEN due[d] \cup {k} ELSE due[d]]
       /\ chan' = [d \in Conns |-> IF Rules /\ open[d] THEN Append(chan[d], SteerMsg(k, c, d)) ELSE chan[d]]
    /\ UNCHANGED <<open, turn, perm, applied, sentTo, shown, got, roster, cancelIgnored,
                   order, rmain, answered, newOpened>>

\* The turn asks for a permission.
Ask ==
    /\ turn # None /\ ~Waiting /\ perm.id < MaxAsks
    /\ LET p == perm.id + 1
           to == IF Rules THEN {d \in Conns : open[d]} ELSE {d \in {turn} : open[d]}
       IN /\ perm' = [id |-> p, decided |-> FALSE]
          /\ sentTo' = to
          /\ chan' = [d \in Conns |-> IF d \in to THEN Append(chan[d], Req(p)) ELSE chan[d]]
    /\ applied' = 0
    /\ UNCHANGED <<open, turn, shown, prompts, sentBy, due, got, roster, cancelIgnored,
                   order, rmain, answered, newOpened>>

\* A client answers the request it shows. The first answer decides, and fx
\* cancels the request on the other clients.
Answer(c) ==
    /\ open[c] /\ shown[c] # 0
    /\ shown' = [shown EXCEPT ![c] = 0]
    /\ IF shown[c] = perm.id /\ ~perm.decided
       THEN /\ perm' = [perm EXCEPT !.decided = TRUE]
            /\ applied' = applied + 1
            /\ sentTo' = {}
            /\ chan' = [d \in Conns |-> IF d \in sentTo \ {c} THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]
       ELSE UNCHANGED <<perm, applied, sentTo, chan>>
    /\ UNCHANGED <<open, turn, prompts, sentBy, due, got, roster, cancelIgnored,
                   order, rmain, answered, newOpened>>

\* session/cancel from a client that has the session open. It stops the
\* turn and cancels a waiting request on every client that has it.
Cancel(c) ==
    /\ open[c] /\ turn # None
    /\ IF Rules \/ c = turn
       THEN /\ turn' = None
            /\ IF Waiting
               THEN /\ perm' = [perm EXCEPT !.decided = TRUE]
                    /\ sentTo' = {}
                    /\ chan' = [d \in Conns |-> IF d \in sentTo THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]
               ELSE UNCHANGED <<perm, sentTo, chan>>
            /\ UNCHANGED cancelIgnored
       ELSE /\ cancelIgnored' = TRUE
            /\ UNCHANGED <<turn, perm, sentTo, chan>>
    /\ UNCHANGED <<open, applied, shown, prompts, sentBy, due, got, roster,
                   order, rmain, answered, newOpened>>

\* The turn ends on its own, once no request waits.
EndTurn ==
    /\ turn # None /\ ~Waiting
    /\ turn' = None
    /\ UNCHANGED <<open, perm, applied, sentTo, shown, chan, prompts, sentBy, due, got, roster,
                   cancelIgnored, order, rmain, answered, newOpened>>

\* The client reads the next message fx wrote to it.
Read(c) ==
    /\ chan[c] # <<>>
    /\ LET m == Head(chan[c]) IN
       /\ chan' = [chan EXCEPT ![c] = Tail(@)]
       /\ shown' = CASE m.kind = "req" /\ open[c] -> [shown EXCEPT ![c] = m.n]
                     [] m.kind = "cancel" /\ shown[c] = m.n -> [shown EXCEPT ![c] = 0]
                     [] OTHER -> shown
       /\ got' = IF m.kind = "echo" /\ open[c] THEN [got EXCEPT ![c] = @ \cup {m.n}]
                 ELSE IF m.kind = "steer" /\ open[c] /\ sentBy[m.n] # c THEN [got EXCEPT ![c] = @ \cup {m.n}]
                 ELSE got
       /\ roster' = IF m.kind = "clients" /\ open[c] THEN [roster EXCEPT ![c] = m.who] ELSE roster
       /\ rmain' = IF m.kind = "clients" /\ open[c] THEN [rmain EXCEPT ![c] = m.main] ELSE rmain
       /\ answered' = IF m.kind = "answer" /\ open[c] THEN [answered EXCEPT ![c] = TRUE] ELSE answered
    /\ UNCHANGED <<open, turn, perm, applied, sentTo, prompts, sentBy, due, cancelIgnored,
                   order, newOpened>>

Next ==
    \/ \E c \in Conns : \E k \in {"new", "load"} : OpenAs(c, k)
    \/ \E c \in Conns : Close(c) \/ Prompt(c) \/ Steer(c) \/ Answer(c) \/ Cancel(c) \/ Read(c)
    \/ Ask \/ EndTurn

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

Pending(c, kind) == \E i \in 1..Len(chan[c]) : chan[c][i].kind = kind
PendingChunk(c) == Pending(c, "echo") \/ Pending(c, "steer")
PendingCancel(c, p) == \E i \in 1..Len(chan[c]) : chan[c][i] = CancelMsg(p)

\* A permission is decided by one answer.
DecidedOnce == applied <= 1

\* A client shows a request that is decided, or no longer the latest, only
\* while its cancellation is on its way.
NoOrphanRequest ==
    \A c \in Conns :
        (shown[c] # 0 /\ (shown[c] # perm.id \/ perm.decided)) => PendingCancel(c, shown[c])

\* A client that has the session open and has read every request fx sent it
\* shows the request that waits.
RequestReachesAll ==
    \A c \in Conns : (open[c] /\ Waiting /\ ~Pending(c, "req")) => shown[c] = perm.id

\* A client that has read every prompt and steer fx sent it holds every prompt
\* the others sent while it had the session open.
EchoComplete == \A c \in Conns : (open[c] /\ ~PendingChunk(c)) => due[c] \subseteq got[c]

\* No client gets its own prompt back. A steer does reach its sender, so the
\* steers a client holds are the others'.
NoSelfEcho == \A c \in Conns : \A k \in got[c] : sentBy[k] # c

\* A client's list of clients is current once it has read every list fx sent.
\* Only a client that lists sh.fx/sessionClients is sent a list.
RosterCurrent ==
    \A c \in Lists : (open[c] /\ ~Pending(c, "clients")) => roster[c] = Roster(open)

\* Any client that has the session open can stop the running turn.
CancelStops == ~cancelIgnored

\* A client that lists the capability and has read the latest list it was
\* sent names the current main client, the first client in the order of opening.
MainCurrent ==
    \A c \in Lists :
        (open[c] /\ ~Pending(c, "clients") /\ roster[c] # NoRoster) => rmain[c] = Head(order)

\* A client that does not list sh.fx/sessionClients is never sent a list.
OptInRoster ==
    \A c \in Conns \ Lists : roster[c] = NoRoster /\ ~Pending(c, "clients")

\* No list is sent when no client has the session open.
NoListWithoutMember ==
    \A c \in Conns : \A i \in 1..Len(chan[c]) :
        chan[c][i].kind = "clients" => chan[c][i].who # {}

\* A client that opened the session with session/load or resume has the list
\* that includes itself before its answer.
JoinerListedBeforeAnswer ==
    \A c \in Lists : (open[c] /\ answered[c] /\ ~newOpened[c]) => c \in roster[c]

\* A client that opened the session with session/new has the answer before any list.
NewListAfterAnswer ==
    \A c \in Lists : (open[c] /\ newOpened[c] /\ ~answered[c]) => roster[c] = NoRoster

\* The order of opening names exactly the clients that have the session open.
OrderMatchesOpen ==
    /\ Len(order) = Cardinality(Roster(open))
    /\ \A c \in Conns : open[c] <=> \E i \in 1..Len(order) : order[i] = c

\* A prompt or steer chunk names its sender as sh.fx/client only for a client
\* that lists sh.fx/sessionClients, and the other clients get it without the key.
ChunkSenderGate ==
    \A c \in Conns : \A i \in 1..Len(chan[c]) :
        chan[c][i].kind \in {"echo", "steer"} =>
            chan[c][i].from = IF c \in Lists THEN sentBy[chan[c][i].n] ELSE None

\* Witnesses: each must be violated, which shows the model reaches the state.
NoUnlistedOpen == \A c \in Conns \ Lists : ~open[c]
NoSteerSent == ~(\E c \in Conns : Pending(c, "steer"))
=============================================================================
