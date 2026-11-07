------------------------- MODULE AcpSharedSession -------------------------
(***************************************************************************)
(* The clients of one shared session in the sh.fx extension to ACP: the   *)
(* "Prompts from other clients", "Permission requests", "Stopping a turn", *)
(* and "Who is connected" parts of "Following a session" in                *)
(* src/protocol/spec/sh-fx.md, which haven't landed in src/acp/ yet.       *)
(*                                                                         *)
(* One session, a few connections that open and close it. fx writes each  *)
(* connection's messages in order, and the client reads them later (Read): *)
(* a permission request, its cancellation, another client's prompt, or     *)
(* the list of connected clients.                                          *)
(*                                                                         *)
(* Rules (Rules = TRUE):                                                   *)
(*  - fx sends a prompt that starts a turn to every other client that has *)
(*    the session open, and never back to its sender. Steers, which every *)
(*    client sees, are in AcpPromptDelivery.                              *)
(*  - fx sends a permission request to every client that has the session  *)
(*    open, and to one that opens it while the request waits. The first   *)
(*    answer decides; fx cancels the request on the others and ignores    *)
(*    later answers. session/cancel cancels a waiting request too.        *)
(*  - Any client that has the session open can stop the running turn.     *)
(*  - fx sends the list of connected clients to every client after one    *)
(*    opens or closes the session.                                         *)
(*                                                                         *)
(* Today (Rules = FALSE): fx serves one client per session, so it acts as *)
(* if only the prompt's sender were there: the request goes to the sender *)
(* only, no client sees another's prompt or the list of clients, and only *)
(* the sender's session/cancel stops the turn.                            *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,       \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Conns,       \* the client connections
    MaxPrompts,  \* prompts in the whole run
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
    prompts,       \* prompts taken so far; prompt k has id k
    sentBy,        \* [1..MaxPrompts -> Conns \cup {None}]
    due,           \* [Conns -> SUBSET 1..MaxPrompts]: other clients' prompts taken while it had the session open
    got,           \* [Conns -> SUBSET 1..MaxPrompts]: prompts the client read
    roster,        \* [Conns -> SUBSET Conns, or NoRoster]: the list of clients it read last
    cancelIgnored  \* a session/cancel from a client with the session open didn't stop the turn

vars == <<open, turn, perm, applied, sentTo, shown, chan, prompts, sentBy, due, got, roster, cancelIgnored>>

Req(p) == [kind |-> "req", n |-> p, who |-> {}]
CancelMsg(p) == [kind |-> "cancel", n |-> p, who |-> {}]
Echo(k) == [kind |-> "echo", n |-> k, who |-> {}]
Clients(set) == [kind |-> "clients", n |-> 0, who |-> set]

Waiting == perm.id # 0 /\ ~perm.decided

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

\* The list of clients goes to every client that has the session open.
RosterOut(c, now) == IF Rules /\ now[c] THEN <<Clients({d \in Conns : now[d]})>> ELSE <<>>

\* A client opens the session (session/new, load, or resume). A waiting
\* request goes to it first, then the list of clients.
Open(c) ==
    /\ ~open[c]
    /\ LET now == [open EXCEPT ![c] = TRUE]
           ask == IF Rules /\ Waiting THEN <<Req(perm.id)>> ELSE <<>>
       IN /\ open' = now
          /\ chan' = [d \in Conns |-> IF d = c THEN chan[d] \o ask \o RosterOut(d, now)
                                      ELSE chan[d] \o RosterOut(d, now)]
          /\ sentTo' = IF Rules /\ Waiting THEN sentTo \cup {c} ELSE sentTo
    /\ UNCHANGED <<turn, perm, applied, shown, prompts, sentBy, due, got, roster, cancelIgnored>>

\* A client closes the session. Its response comes after every message fx
\* wrote before it, so the client acts on the close once it has read them.
\* fx drops the request it can no longer answer, and the turn goes on.
Close(c) ==
    /\ open[c] /\ chan[c] = <<>>
    /\ LET now == [open EXCEPT ![c] = FALSE] IN
       /\ open' = now
       /\ chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now)]
    /\ sentTo' = sentTo \ {c}
    /\ shown' = [shown EXCEPT ![c] = 0]
    /\ due' = [due EXCEPT ![c] = {}]
    /\ got' = [got EXCEPT ![c] = {}]
    /\ roster' = [roster EXCEPT ![c] = NoRoster]
    /\ UNCHANGED <<turn, perm, applied, prompts, sentBy, cancelIgnored>>

\* A client's prompt starts a turn, and goes to the other clients.
Prompt(c) ==
    /\ open[c] /\ turn = None /\ prompts < MaxPrompts
    /\ LET k == prompts + 1 IN
       /\ prompts' = k
       /\ sentBy' = [sentBy EXCEPT ![k] = c]
       /\ due' = [d \in Conns |-> IF open[d] /\ d # c THEN due[d] \cup {k} ELSE due[d]]
       /\ chan' = [d \in Conns |-> IF Rules /\ open[d] /\ d # c THEN Append(chan[d], Echo(k)) ELSE chan[d]]
    /\ turn' = c
    /\ UNCHANGED <<open, perm, applied, sentTo, shown, got, roster, cancelIgnored>>

\* The turn asks for a permission.
Ask ==
    /\ turn # None /\ ~Waiting /\ perm.id < MaxAsks
    /\ LET p == perm.id + 1
           to == IF Rules THEN {d \in Conns : open[d]} ELSE {d \in {turn} : open[d]}
       IN /\ perm' = [id |-> p, decided |-> FALSE]
          /\ sentTo' = to
          /\ chan' = [d \in Conns |-> IF d \in to THEN Append(chan[d], Req(p)) ELSE chan[d]]
    /\ applied' = 0
    /\ UNCHANGED <<open, turn, shown, prompts, sentBy, due, got, roster, cancelIgnored>>

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
    /\ UNCHANGED <<open, turn, prompts, sentBy, due, got, roster, cancelIgnored>>

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
    /\ UNCHANGED <<open, applied, shown, prompts, sentBy, due, got, roster>>

\* The turn ends on its own, once no request waits.
EndTurn ==
    /\ turn # None /\ ~Waiting
    /\ turn' = None
    /\ UNCHANGED <<open, perm, applied, sentTo, shown, chan, prompts, sentBy, due, got, roster, cancelIgnored>>

\* The client reads the next message fx wrote to it.
Read(c) ==
    /\ chan[c] # <<>>
    /\ LET m == Head(chan[c]) IN
       /\ chan' = [chan EXCEPT ![c] = Tail(@)]
       /\ shown' = CASE m.kind = "req" /\ open[c] -> [shown EXCEPT ![c] = m.n]
                     [] m.kind = "cancel" /\ shown[c] = m.n -> [shown EXCEPT ![c] = 0]
                     [] OTHER -> shown
       /\ got' = IF m.kind = "echo" /\ open[c] THEN [got EXCEPT ![c] = @ \cup {m.n}] ELSE got
       /\ roster' = IF m.kind = "clients" /\ open[c] THEN [roster EXCEPT ![c] = m.who] ELSE roster
    /\ UNCHANGED <<open, turn, perm, applied, sentTo, prompts, sentBy, due, cancelIgnored>>

Next ==
    \/ \E c \in Conns : Open(c) \/ Close(c) \/ Prompt(c) \/ Answer(c) \/ Cancel(c) \/ Read(c)
    \/ Ask \/ EndTurn

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

Pending(c, kind) == \E i \in 1..Len(chan[c]) : chan[c][i].kind = kind
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

\* A client that has read every prompt fx sent it holds every prompt the
\* others sent while it had the session open.
EchoComplete == \A c \in Conns : (open[c] /\ ~Pending(c, "echo")) => due[c] \subseteq got[c]

\* No client gets its own prompt back.
NoSelfEcho == \A c \in Conns : \A k \in got[c] : sentBy[k] # c

\* A client's list of clients is current once it has read every list fx sent.
RosterCurrent ==
    \A c \in Conns : (open[c] /\ ~Pending(c, "clients")) => roster[c] = {d \in Conns : open[d]}

\* Any client that has the session open can stop the running turn.
CancelStops == ~cancelIgnored
=============================================================================
