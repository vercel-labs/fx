---------------------------- MODULE AcpFollow ----------------------------
(***************************************************************************)
(* Following a session and catching up, as the sh.fx spec's "Following a  *)
(* session" section defines them (src/protocol/spec/sh-fx.md), with the   *)
(* stable message ids of fix X21. The rules have not landed in src/acp/   *)
(* yet: `Rules` set to FALSE gives fx today, and the AcpFollowToday-*.cfg  *)
(* configs show each rule failing there.                                   *)
(*                                                                         *)
(*  - A session can be open on several connections. A client joins with   *)
(*    session/load, which replays every saved turn, or with               *)
(*    session/resume, which a client that already holds the session uses; *)
(*    either works while another connection has the session open.         *)
(*  - While the session is open elsewhere, it keeps its folder, and the   *)
(*    answer gives that folder.                                            *)
(*  - fx sends each saved turn to every connection that has the session   *)
(*    open, with the session's new position.                               *)
(*  - A client that sends the position it holds on session/load gets only *)
(*    the turns saved after it. A position fx doesn't know, such as one   *)
(*    from before a compaction rewrote the log, gets the whole session,   *)
(*    and the answer says which.                                           *)
(*  - A replayed message keeps the id it had when it was live (X21).       *)
(*  - session/close closes the session on that connection only. While     *)
(*    another connection has it open, a running turn goes on.             *)
(*                                                                         *)
(* So every connection that has the session open holds exactly the saved  *)
(* turns, in order, with no gap and no repeat.                             *)
(*                                                                         *)
(* Today (Rules = FALSE): a session open on one connection is busy for    *)
(* others; a load ignores the position and replays everything without     *)
(* saying so, and no position is sent; and replayed messages get new ids. *)
(*                                                                         *)
(* A turn is a number; a compaction replaces the log with one summary     *)
(* turn, 0, in a new generation.                                           *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    Rules,      \* TRUE: the sh.fx rules; FALSE: fx today
    Conns,      \* the client connections
    Folders,    \* the folders a client may send as cwd
    MaxTurns,   \* turns the session may run
    MaxCompactions

ASSUME Rules \in BOOLEAN /\ MaxTurns \in Nat /\ MaxCompactions \in Nat

NoPos == [gen |-> -1, n |-> -1]
NoObs == [op |-> "none", conn |-> "none", ok |-> TRUE, replay |-> "none", cwd |-> "none"]

\* What a connection's client holds: its copy of the session's messages, the
\* position fx last gave it, and whether the session is open on it.
Client == [open |-> FALSE, has |-> <<>>, pos |-> NoPos]

Range(s) == {s[k] : k \in DOMAIN s}

VARIABLES
    saved,      \* the turns in the session's log, in order
    gen,        \* the log's generation
    running,    \* whether a turn runs
    turnsRun,   \* turns started so far
    compactions,
    folder,     \* the session's folder, or "none" before anyone opened it
    client,     \* [Conns -> Client]
    last        \* what the latest step answered
vars == <<saved, gen, running, turnsRun, compactions, folder, client, last>>

OpenConns == {c \in Conns : client[c].open}
OpenElsewhere(c) == OpenConns \ {c} # {}

\* The messages of `turns` as a replay sends them. A replayed message keeps
\* its live id under the rules; today it gets a new one.
Replayed(turns) == [k \in 1..Len(turns) |-> [turn |-> turns[k], id |-> IF Rules THEN turns[k] ELSE -1]]
Live(t) == [turn |-> t, id |-> t]
Turns(msgs) == [k \in 1..Len(msgs) |-> msgs[k].turn]

Init ==
    /\ saved = <<>>
    /\ gen = 0
    /\ running = FALSE
    /\ turnsRun = 0
    /\ compactions = 0
    /\ folder = "none"
    /\ client = [c \in Conns |-> Client]
    /\ last = NoObs

\* session/load on c, with the client's own position or none.
Load(c, w, withPos) ==
    /\ ~client[c].open
    /\ IF ~Rules /\ OpenElsewhere(c)
       THEN \* Today the session is busy for a second client.
            /\ last' = [op |-> "load", conn |-> c, ok |-> FALSE, replay |-> "none", cwd |-> "none"]
            /\ UNCHANGED <<saved, gen, running, turnsRun, compactions, folder, client>>
       ELSE LET p == client[c].pos
                known == Rules /\ withPos /\ p.gen = gen /\ 0 <= p.n /\ p.n <= Len(saved)
                kept == IF known THEN SubSeq(client[c].has, 1, p.n) ELSE <<>>
                rest == IF known THEN SubSeq(saved, p.n + 1, Len(saved)) ELSE saved
                f == IF OpenElsewhere(c) THEN folder ELSE w
            IN /\ client' = [client EXCEPT ![c] = [open |-> TRUE, has |-> kept \o Replayed(rest),
                                                    pos |-> IF Rules THEN [gen |-> gen, n |-> Len(saved)] ELSE p]]
               /\ folder' = f
               /\ last' = [op |-> "load", conn |-> c, ok |-> TRUE,
                           replay |-> IF ~Rules THEN "none" ELSE IF known THEN "after_position" ELSE "full",
                           cwd |-> f]
               /\ UNCHANGED <<saved, gen, running, turnsRun, compactions>>

\* session/resume on c, by a client that already holds every saved turn.
Resume(c, w) ==
    /\ ~client[c].open
    /\ Turns(client[c].has) = saved
    /\ IF ~Rules /\ OpenElsewhere(c)
       THEN /\ last' = [op |-> "resume", conn |-> c, ok |-> FALSE, replay |-> "none", cwd |-> "none"]
            /\ UNCHANGED <<saved, gen, running, turnsRun, compactions, folder, client>>
       ELSE LET f == IF OpenElsewhere(c) THEN folder ELSE w IN
            /\ client' = [client EXCEPT ![c].open = TRUE,
                                        ![c].pos = IF Rules THEN [gen |-> gen, n |-> Len(saved)] ELSE client[c].pos]
            /\ folder' = f
            /\ last' = [op |-> "resume", conn |-> c, ok |-> TRUE, replay |-> "none", cwd |-> f]
            /\ UNCHANGED <<saved, gen, running, turnsRun, compactions>>

\* A client with the session open sends a prompt, and a turn starts.
TurnStart ==
    /\ ~running /\ OpenConns # {} /\ turnsRun < MaxTurns
    /\ running' = TRUE
    /\ turnsRun' = turnsRun + 1
    /\ last' = [NoObs EXCEPT !.op = "turn_start"]
    /\ UNCHANGED <<saved, gen, compactions, folder, client>>

\* fx saves the running turn and sends it, with the new position, to every
\* connection that has the session open.
TurnSave ==
    /\ running
    /\ running' = FALSE
    /\ saved' = Append(saved, turnsRun)
    /\ client' = [c \in Conns |->
            IF client[c].open
            THEN [client[c] EXCEPT !.has = Append(@, Live(turnsRun)),
                                   !.pos = IF Rules THEN [gen |-> gen, n |-> Len(saved) + 1] ELSE @]
            ELSE client[c]]
    /\ last' = [NoObs EXCEPT !.op = "turn_save"]
    /\ UNCHANGED <<gen, turnsRun, compactions, folder>>

\* A compaction rewrites the log while no client has the session open.
Compact ==
    /\ ~running /\ OpenConns = {} /\ compactions < MaxCompactions
    /\ compactions' = compactions + 1
    /\ gen' = gen + 1
    /\ saved' = <<0>>
    /\ last' = [NoObs EXCEPT !.op = "compact"]
    /\ UNCHANGED <<running, turnsRun, folder, client>>

\* session/close on c, or its connection closing. The client keeps its copy
\* and position. The last close of a running turn stops it, and fx saves it.
Close(c) ==
    /\ client[c].open
    /\ client' = [client EXCEPT ![c].open = FALSE]
    /\ last' = [NoObs EXCEPT !.op = "close", !.conn = c]
    /\ IF running /\ ~OpenElsewhere(c)
       THEN /\ running' = FALSE
            /\ saved' = Append(saved, turnsRun)
       ELSE UNCHANGED <<running, saved>>
    /\ UNCHANGED <<gen, turnsRun, compactions, folder>>

Next ==
    \/ \E c \in Conns, w \in Folders : Load(c, w, TRUE) \/ Load(c, w, FALSE) \/ Resume(c, w)
    \/ \E c \in Conns : Close(c)
    \/ TurnStart \/ TurnSave \/ Compact

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ running \in BOOLEAN
    /\ folder \in Folders \cup {"none"}
    /\ \A c \in Conns : client[c].open \in BOOLEAN

\* Every connection with the session open holds exactly the saved turns, in
\* order: no gap and no repeat.
InSync == \A c \in OpenConns : Turns(client[c].has) = saved

\* A replayed message has the id it had live (X21).
StableIds == \A c \in Conns : \A k \in DOMAIN client[c].has : client[c].has[k].id = client[c].has[k].turn

\* A client can join a session that another connection has open.
JoinWorks == [][(last'.op \in {"load", "resume"} /\ OpenElsewhere(last'.conn)) => last'.ok]_vars

\* Each open connection holds the session's current position.
PositionCurrent == \A c \in OpenConns : client[c].pos = [gen |-> gen, n |-> Len(saved)]

\* A load says how it replayed: after the client's position when fx knows it,
\* otherwise the whole session.
ReplaySaid == (last.op = "load" /\ last.ok) => last.replay \in {"after_position", "full"}

\* A client that joins while the session is open elsewhere doesn't change its
\* folder, and is told the session's folder.
KeepsFolder ==
    [][(last'.op \in {"load", "resume"} /\ last'.ok /\ OpenElsewhere(last'.conn)) =>
           /\ folder' = folder
           /\ last'.cwd = folder]_vars

\* Closing on one connection leaves a running turn running while another
\* connection has the session open.
CloseOnlyDetaches ==
    [][(last'.op = "close" /\ OpenElsewhere(last'.conn)) => running' = running]_vars
=============================================================================
