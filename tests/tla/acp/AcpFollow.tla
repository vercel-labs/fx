---------------------------- MODULE AcpFollow ----------------------------
(***************************************************************************)
(* Following a session and catching up, as the sh.fx spec's "Following a  *)
(* session" section defines them (src/protocol/spec/sh-fx.md), with the   *)
(* stable message ids. The rules have not landed in src/acp/              *)
(* yet: `Rules` set to FALSE gives fx today, and the AcpFollowToday-*.cfg  *)
(* configs show each rule failing there.                                   *)
(*                                                                         *)
(*  - A session can be open on several connections. A client joins with   *)
(*    session/load, or with session/resume, which a client that holds      *)
(*    every saved turn uses; either works while another connection has     *)
(*    the session open.                                                    *)
(*  - While the session is open elsewhere, it keeps its folder, and the    *)
(*    answer gives that folder.                                            *)
(*  - fx sends each saved turn to every connection that has the session    *)
(*    open, with the session's new position.                               *)
(*  - A client that sends the position it holds on session/load gets only  *)
(*    the turns saved after it. A position fx doesn't know gets the whole  *)
(*    session, and the answer says which. A client that has lost its      *)
(*    messages sends no position.                                          *)
(*  - A client keeps its messages together with its position. It keeps    *)
(*    its copy when the answer says "after_position", and drops it when    *)
(*    the answer says "full", so a wrong answer loses or repeats turns.    *)
(*  - A replayed message keeps the id it had when it was live.             *)
(*  - session/close closes the session on that connection only. While      *)
(*    another connection has it open, a running turn goes on.              *)
(*  - A compaction changes only what fx sends the model. The saved turns,  *)
(*    their positions and what a load replays stay the same, so a          *)
(*    compaction can happen while connections have the session open.       *)
(*                                                                         *)
(* So every connection that has the session open holds exactly the saved  *)
(* turns, in order, with no gap and no repeat.                             *)
(*                                                                         *)
(* Today (Rules = FALSE): a session open on one connection is busy for    *)
(* others; a load ignores the position and replays everything without     *)
(* saying so, and no position is sent; and replayed messages get new ids. *)
(*                                                                         *)
(* A turn is a number. A compaction changes only fx's model context, which *)
(* this model counts and nothing else.                                     *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    Rules,      \* TRUE: the sh.fx rules; FALSE: fx today
    Conns,      \* the client connections
    Folders,    \* the folders a client may send as cwd
    MaxTurns,   \* turns the session may run
    MaxCompactions

ASSUME Rules \in BOOLEAN /\ MaxTurns \in Nat /\ MaxCompactions \in Nat

NoPos == -1
NoObs == [op |-> "none", conn |-> "none", ok |-> TRUE, replay |-> "none", cwd |-> "none"]

\* What a connection's client holds: its copy of the session's messages, the
\* position it holds (the number of saved turns in that copy), and whether it
\* has lost its messages.
Client == [open |-> FALSE, has |-> <<>>, pos |-> NoPos, lost |-> FALSE]

Range(s) == {s[k] : k \in DOMAIN s}

VARIABLES
    saved,      \* the turns in the session's log, in order
    running,    \* whether a turn runs
    turnsRun,   \* turns started so far
    compactions,\* compactions so far
    folder,     \* the session's folder, or \"none\" before anyone opened it
    client,     \* [Conns -> Client]
    last        \* what the latest step answered
vars == <<saved, running, turnsRun, compactions, folder, client, last>>

OpenConns == {c \in Conns : client[c].open}
OpenElsewhere(c) == OpenConns \ {c} # {}

\* The messages of `turns` as a replay sends them. A replayed message keeps
\* its live id under the rules; today it gets a new one.
Replayed(turns) == [k \in 1..Len(turns) |-> [turn |-> turns[k], id |-> IF Rules THEN turns[k] ELSE -1]]
Live(t) == [turn |-> t, id |-> t]
Turns(msgs) == [k \in 1..Len(msgs) |-> msgs[k].turn]

\* The first p messages of a client's copy. A copy shorter than p belongs to a
\* client that lost messages but kept its position, which the rules forbid. It
\* keeps what it has, so InSync reports the missing turns rather than the
\* model stopping with an error.
Prefix(msgs, p) == SubSeq(msgs, 1, IF p < Len(msgs) THEN p ELSE Len(msgs))

Init ==
    /\ saved = <<>>
    /\ running = FALSE
    /\ turnsRun = 0
    /\ compactions = 0
    /\ folder = "none"
    /\ client = [c \in Conns |-> Client]
    /\ last = NoObs

\* session/load on c, with the client's own position or none. A client that
\* has lost its messages sends no position.
Load(c, w, withPos) ==
    /\ ~client[c].open
    /\ (withPos => ~client[c].lost)
    /\ IF ~Rules /\ OpenElsewhere(c)
       THEN \* Today the session is busy for a second client.
            /\ last' = [op |-> "load", conn |-> c, ok |-> FALSE, replay |-> "none", cwd |-> "none"]
            /\ UNCHANGED <<saved, running, turnsRun, compactions, folder, client>>
       ELSE LET p == client[c].pos
                known == Rules /\ withPos /\ 0 <= p /\ p <= Len(saved)
                label == IF ~Rules THEN "none" ELSE IF known THEN "after_position" ELSE "full"
                rest == IF known THEN SubSeq(saved, p + 1, Len(saved)) ELSE saved
                f == IF OpenElsewhere(c) THEN folder ELSE w
            IN /\ last' = [op |-> "load", conn |-> c, ok |-> TRUE, replay |-> label, cwd |-> f]
               /\ folder' = f
               /\ client' = [client EXCEPT ![c] =
                                [open |-> TRUE,
                                 has |-> (IF last'.replay = "after_position" THEN Prefix(client[c].has, p) ELSE <<>>)
                                         \o Replayed(rest),
                                 pos |-> IF Rules THEN Len(saved) ELSE p,
                                 lost |-> FALSE]]
               /\ UNCHANGED <<saved, running, turnsRun, compactions>>

\* session/resume on c, by a client that already holds every saved turn.
Resume(c, w) ==
    /\ ~client[c].open
    /\ Turns(client[c].has) = saved
    /\ IF ~Rules /\ OpenElsewhere(c)
       THEN /\ last' = [op |-> "resume", conn |-> c, ok |-> FALSE, replay |-> "none", cwd |-> "none"]
            /\ UNCHANGED <<saved, running, turnsRun, compactions, folder, client>>
       ELSE LET f == IF OpenElsewhere(c) THEN folder ELSE w IN
            /\ client' = [client EXCEPT ![c].open = TRUE,
                                        ![c].pos = IF Rules THEN Len(saved) ELSE client[c].pos,
                                        ![c].lost = FALSE]
            /\ folder' = f
            /\ last' = [op |-> "resume", conn |-> c, ok |-> TRUE, replay |-> "none", cwd |-> f]
            /\ UNCHANGED <<saved, running, turnsRun, compactions>>

\* A closed client loses its messages. It keeps its position or drops it, and
\* under the rules it sends no position until it loads the session again.
Forget(c) ==
    /\ ~client[c].open /\ ~client[c].lost
    /\ \/ client' = [client EXCEPT ![c].has = <<>>, ![c].lost = TRUE]
       \/ client' = [client EXCEPT ![c].has = <<>>, ![c].pos = NoPos, ![c].lost = TRUE]
    /\ last' = [NoObs EXCEPT !.op = "forget", !.conn = c]
    /\ UNCHANGED <<saved, running, turnsRun, compactions, folder>>

\* A client with the session open sends a prompt, and a turn starts.
TurnStart ==
    /\ ~running /\ OpenConns # {} /\ turnsRun < MaxTurns
    /\ running' = TRUE
    /\ turnsRun' = turnsRun + 1
    /\ last' = [NoObs EXCEPT !.op = "turn_start"]
    /\ UNCHANGED <<saved, compactions, folder, client>>

\* fx saves the running turn and sends it, with the new position, to every
\* connection that has the session open.
TurnSave ==
    /\ running
    /\ running' = FALSE
    /\ saved' = Append(saved, turnsRun)
    /\ client' = [c \in Conns |->
            IF client[c].open
            THEN [client[c] EXCEPT !.has = Append(@, Live(turnsRun)),
                                   !.pos = IF Rules THEN Len(saved) + 1 ELSE @]
            ELSE client[c]]
    /\ last' = [NoObs EXCEPT !.op = "turn_save"]
    /\ UNCHANGED <<turnsRun, compactions, folder>>

\* fx compacts the context it sends the model. Nothing saved changes, so this
\* can happen while connections have the session open.
Compact ==
    /\ compactions < MaxCompactions
    /\ compactions' = compactions + 1
    /\ saved' = saved
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
    /\ UNCHANGED <<turnsRun, compactions, folder>>

Next ==
    \/ \E c \in Conns, w \in Folders : Load(c, w, TRUE) \/ Load(c, w, FALSE) \/ Resume(c, w)
    \/ \E c \in Conns : Close(c) \/ Forget(c)
    \/ TurnStart \/ TurnSave \/ Compact

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ running \in BOOLEAN
    /\ folder \in Folders \cup {"none"}
    /\ \A c \in Conns : client[c].open \in BOOLEAN /\ client[c].lost \in BOOLEAN

\* Every connection with the session open holds exactly the saved turns, in
\* order: no gap and no repeat.
InSync == \A c \in OpenConns : Turns(client[c].has) = saved

\* A replayed message has the id it had live.
StableIds == \A c \in Conns : \A k \in DOMAIN client[c].has : client[c].has[k].id = client[c].has[k].turn

\* A client can join a session that another connection has open.
JoinWorks == [][(last'.op \in {"load", "resume"} /\ OpenElsewhere(last'.conn)) => last'.ok]_vars

\* Each open connection holds the session's current position.
PositionCurrent == \A c \in OpenConns : client[c].pos = Len(saved)

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
