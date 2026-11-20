-------------------------- MODULE AcpForkRewind --------------------------
(***************************************************************************)
(* Fork and rewind in the sh.fx extension to ACP: the "Fork and rewind"   *)
(* section of src/protocol/spec/sh-fx.md, which hasn't landed in src/acp/ *)
(* yet.                                                                    *)
(*                                                                         *)
(* One source session whose turns run and are saved, and clients that     *)
(* open it, read what fx writes to them in order, and load it again. A    *)
(* position names a generation of the session's log and a turn count, as  *)
(* in AcpFollow: a rewind starts a new generation.                         *)
(*                                                                         *)
(* Rules (Rules = TRUE):                                                   *)
(*  - A fork before prompt i copies the turns before it into a new         *)
(*    session and leaves the source as it was.                             *)
(*  - A rewind before prompt i keeps the turns before it in place. fx      *)
(*    tells the other clients that have the session open, and the caller  *)
(*    gets the new history from its response.                              *)
(*  - A catch-up from a position of another generation replays the whole  *)
(*    session.                                                             *)
(*  - Neither runs while a turn runs.                                      *)
(*                                                                         *)
(* Today (Rules = FALSE): fx's ACP server has neither method, so both get *)
(* -32601.                                                                 *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,       \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Conns,       \* the client connections
    MaxTurns,    \* turns in the whole run
    MaxForks,    \* forks in the whole run
    MaxRewinds   \* rewinds in the whole run

VARIABLES
    log,       \* the source's saved turns, by id
    gen,       \* the generation of the source's log
    running,   \* a turn runs in the source
    turns,     \* turns run, which number them
    forks,     \* each fork: [log, src, point]
    rw,        \* the latest rewind: [old, point]; point 0 is none
    rewinds,   \* rewinds done
    open,      \* [Conns -> BOOLEAN]
    copy,      \* [Conns -> Seq]: the client's copy of the source's history
    pos,       \* [Conns -> [g, n]]: the client's position
    stale,     \* [Conns -> BOOLEAN]: the client read that its history was replaced
    chan,      \* [Conns -> Seq(message)]
    flags      \* the mistakes the properties rule out, as a set of names

vars == <<log, gen, running, turns, forks, rw, rewinds, open, copy, pos, stale, chan, flags>>

TurnMsg(k, g, n) == [kind |-> "turn", k |-> k, g |-> g, n |-> n]
Replaced == [kind |-> "replaced", k |-> 0, g |-> 0, n |-> 0]

Init ==
    /\ log = <<>>
    /\ gen = 1
    /\ running = FALSE
    /\ turns = 0
    /\ forks = <<>>
    /\ rw = [old |-> <<>>, point |-> 0]
    /\ rewinds = 0
    /\ open = [c \in Conns |-> FALSE]
    /\ copy = [c \in Conns |-> <<>>]
    /\ pos = [c \in Conns |-> [g |-> 0, n |-> 0]]
    /\ stale = [c \in Conns |-> FALSE]
    /\ chan = [c \in Conns |-> <<>>]
    /\ flags = {}

\* session/load with no position: the whole session.
Open(c) ==
    /\ ~open[c]
    /\ open' = [open EXCEPT ![c] = TRUE]
    /\ copy' = [copy EXCEPT ![c] = log]
    /\ pos' = [pos EXCEPT ![c] = [g |-> gen, n |-> Len(log)]]
    /\ stale' = [stale EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<log, gen, running, turns, forks, rw, rewinds, chan, flags>>

Close(c) ==
    /\ open[c] /\ chan[c] = <<>>
    /\ open' = [open EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<log, gen, running, turns, forks, rw, rewinds, copy, pos, stale, chan, flags>>

StartTurn ==
    /\ ~running /\ turns < MaxTurns
    /\ running' = TRUE
    /\ turns' = turns + 1
    /\ UNCHANGED <<log, gen, forks, rw, rewinds, open, copy, pos, stale, chan, flags>>

\* The turn is saved, and goes to every client that has the session open
\* with the new position.
SaveTurn ==
    /\ running
    /\ running' = FALSE
    /\ log' = Append(log, turns)
    /\ chan' = [c \in Conns |-> IF open[c] THEN Append(chan[c], TurnMsg(turns, gen, Len(log) + 1)) ELSE chan[c]]
    /\ UNCHANGED <<gen, turns, forks, rw, rewinds, open, copy, pos, stale, flags>>

\* session/fork before prompt i, or of the whole session when i is past the last.
Fork(c, i) ==
    /\ open[c] /\ Len(forks) < MaxForks /\ i \in 1..(Len(log) + 1)
    /\ IF ~Rules
       THEN /\ flags' = flags \cup {"fork_refused"}
            /\ UNCHANGED <<log, forks>>
       ELSE /\ ~running
            /\ forks' = Append(forks, [log |-> SubSeq(log, 1, i - 1), src |-> log, point |-> i])
            /\ UNCHANGED <<log, flags>>
    /\ UNCHANGED <<gen, running, turns, rw, rewinds, open, copy, pos, stale, chan>>

\* _sh.fx/session/rewind before prompt i, from client c. Its response comes
\* after every message fx wrote before it, so the client acts on it once it
\* has read them.
Rewind(c, i) ==
    /\ open[c] /\ chan[c] = <<>> /\ rewinds < MaxRewinds /\ i \in 1..Len(log)
    /\ IF ~Rules
       THEN /\ flags' = flags \cup {"rewind_refused"}
            /\ UNCHANGED <<log, gen, rw, rewinds, copy, pos, chan>>
       ELSE /\ ~running
            /\ LET kept == SubSeq(log, 1, i - 1) IN
               /\ log' = kept
               /\ gen' = gen + 1
               /\ rw' = [old |-> log, point |-> i]
               /\ rewinds' = rewinds + 1
               /\ copy' = [copy EXCEPT ![c] = kept]
               /\ pos' = [pos EXCEPT ![c] = [g |-> gen + 1, n |-> Len(kept)]]
               /\ chan' = [d \in Conns |-> IF open[d] /\ d # c THEN Append(chan[d], Replaced) ELSE chan[d]]
            /\ UNCHANGED flags
    /\ UNCHANGED <<running, turns, forks, open, stale>>

\* The client reads the next message fx wrote to it.
Read(c) ==
    /\ chan[c] # <<>>
    /\ LET m == Head(chan[c]) IN
       /\ chan' = [chan EXCEPT ![c] = Tail(@)]
       /\ copy' = IF m.kind = "turn" /\ ~stale[c] THEN [copy EXCEPT ![c] = Append(@, m.k)] ELSE copy
       /\ pos' = IF m.kind = "turn" /\ ~stale[c] THEN [pos EXCEPT ![c] = [g |-> m.g, n |-> m.n]] ELSE pos
       /\ stale' = IF m.kind = "replaced" THEN [stale EXCEPT ![c] = TRUE] ELSE stale
    /\ UNCHANGED <<log, gen, running, turns, forks, rw, rewinds, open, flags>>

\* The client loads the session again from its position. A position of the
\* current generation replays the turns after it; any other, the whole
\* session.
Reload(c) ==
    /\ open[c] /\ chan[c] = <<>>
    /\ LET known == Rules /\ pos[c].g = gen /\ pos[c].n <= Len(log) IN
       copy' = [copy EXCEPT ![c] = IF known THEN SubSeq(copy[c], 1, pos[c].n) \o SubSeq(log, pos[c].n + 1, Len(log)) ELSE log]
    /\ pos' = [pos EXCEPT ![c] = [g |-> gen, n |-> Len(log)]]
    /\ stale' = [stale EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<log, gen, running, turns, forks, rw, rewinds, open, chan, flags>>

Next ==
    \/ StartTurn \/ SaveTurn
    \/ \E c \in Conns : Open(c) \/ Close(c) \/ Read(c) \/ Reload(c)
    \/ \E c \in Conns, i \in 1..(MaxTurns + 1) : Fork(c, i) \/ Rewind(c, i)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

Pending(c) == \E j \in 1..Len(chan[c]) : chan[c][j].kind \in {"turn", "replaced"}

\* A fork holds exactly the source's turns before its prompt.
ForkIsPrefix == \A j \in 1..Len(forks) : forks[j].log = SubSeq(forks[j].src, 1, forks[j].point - 1)

\* A fork leaves the source as it was.
ForkLeavesSource == [][Len(forks') > Len(forks) => log' = log]_vars

\* A rewind keeps exactly the turns before its prompt; later turns follow them.
RewindIsPrefix ==
    rw.point = 0 \/ (Len(log) >= rw.point - 1 /\ SubSeq(log, 1, rw.point - 1) = SubSeq(rw.old, 1, rw.point - 1))

\* A client that has read everything fx sent, and wasn't told its history
\* was replaced, holds the session's history.
InSync == \A c \in Conns : (open[c] /\ ~Pending(c) /\ ~stale[c]) => copy[c] = log

\* Neither a fork nor a rewind happens while a turn runs.
NotWhileRunning ==
    [][running => (Len(forks') = Len(forks) /\ rewinds' = rewinds)]_vars

\* session/fork works.
ForkAvailable == "fork_refused" \notin flags

\* _sh.fx/session/rewind works.
RewindAvailable == "rewind_refused" \notin flags
=============================================================================
