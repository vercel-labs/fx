-------------------------- MODULE AcpSessionState --------------------------
(***************************************************************************)
(* Session state, status, and list changes in the sh.fx extension to ACP: *)
(* the "Session status and list changes" section of                        *)
(* src/protocol/spec/sh-fx.md, which hasn't landed in src/acp/ yet.        *)
(*                                                                         *)
(* fx writes messages to each connection in order; the client reads them  *)
(* later (Deliver). A message is a session's state, an update of a turn,  *)
(* or a hint that a folder's list changed.                                 *)
(*                                                                         *)
(* Rules (Rules = TRUE):                                                   *)
(*  - fx sends a session's state to every connection that has it open     *)
(*    each time it changes, and the current state when a connection opens *)
(*    it, so a connection's view is current once it has read its queue.   *)
(*  - running comes before a turn's updates; idle carries the turn's      *)
(*    stopReason.                                                          *)
(*  - session/status says open while any connection holds the session,   *)
(*    and gives its state.                                                 *)
(*  - session/list answers at once, even during a turn (X24).             *)
(*  - After a session in a folder is saved for the first time, saves a    *)
(*    turn, gets a title, or is deleted, fx sends a hint to every         *)
(*    connection that listed that folder or every folder.                 *)
(*                                                                         *)
(* Today (Rules = FALSE): fx sends no state and no hint; session/status   *)
(* is an unknown method, which gets -32601, or -32600 while a turn runs   *)
(* on the connection; and session/list gets -32600 while a turn runs on   *)
(* the connection.                                                         *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Rules,          \* TRUE: the sh.fx rules; FALSE: fx's ACP path today
    Conns,          \* the client connections
    Sessions,       \* the sessions
    FolderOf,       \* [Sessions -> folder]
    MaxTurns,       \* turns in the whole run
    MaxChanges,     \* retitles and deletes in the whole run
    AllowApproval   \* whether a turn can wait for a permission answer

Folders == {FolderOf[s] : s \in Sessions}
States == {"running", "requires_action", "idle"}
All == "*"     \* session/list with no cwd

VARIABLES
    exists,     \* [Sessions -> BOOLEAN]: session/new has created it
    open,       \* [Conns -> SUBSET Sessions]: open on the connection
    st,         \* [Sessions -> States]
    owner,      \* [Sessions -> Conns \cup {"none"}]: the connection whose prompt runs
    saved,      \* [Sessions -> BOOLEAN]: on disk
    deleted,    \* [Sessions -> BOOLEAN]
    ver,        \* [Folders -> Nat]: changes to the folder's list
    chan,       \* [Conns -> Seq(message)]: written by fx, not yet read
    view,       \* [Conns -> [Sessions -> States \cup {"none"}]]: the state the client read last
    subs,       \* [Conns -> SUBSET (Folders \cup {All})]: what the client has listed
    seen,       \* [Conns -> [Folders -> Int]]: the version of each folder's list the client holds
    hinted,     \* [Conns -> SUBSET Folders]: hints read since the client last listed the folder
    refused,    \* the last session/list got -32600 (X24)
    badOrder,   \* an update was read while the client's view said the session wasn't running
    turns, changes

vars == <<exists, open, st, owner, saved, deleted, ver, chan, view, subs, seen,
          hinted, refused, badOrder, turns, changes>>

Held(s) == \E c \in Conns : s \in open[c]
Covers(c, f) == f \in subs[c] \/ All \in subs[c]
Busy(c) == \E s \in Sessions : owner[s] = c

StateMsg(s, state, stop) == [kind |-> "state", s |-> s, state |-> state, stop |-> stop, f |-> "none"]
HintMsg(f) == [kind |-> "hint", s |-> "none", state |-> "none", stop |-> "none", f |-> f]
UpdateMsg(s) == [kind |-> "update", s |-> s, state |-> "none", stop |-> "none", f |-> "none"]

\* What fx writes to connection c when session s changes: its new state, and
\* a hint for its folder when the list changed too.
Out(c, s, state, stop, listChanged) ==
    LET stateOut == IF Rules /\ state # "none" /\ s \in open[c] THEN <<StateMsg(s, state, stop)>> ELSE <<>>
        hintOut == IF Rules /\ listChanged /\ Covers(c, FolderOf[s]) THEN <<HintMsg(FolderOf[s])>> ELSE <<>>
    IN stateOut \o hintOut

Write(s, state, stop, listChanged) ==
    chan' = [c \in Conns |-> chan[c] \o Out(c, s, state, stop, listChanged)]

Bump(s) == ver' = [ver EXCEPT ![FolderOf[s]] = @ + 1]

Init ==
    /\ exists = [s \in Sessions |-> FALSE]
    /\ open = [c \in Conns |-> {}]
    /\ st = [s \in Sessions |-> "idle"]
    /\ owner = [s \in Sessions |-> "none"]
    /\ saved = [s \in Sessions |-> FALSE]
    /\ deleted = [s \in Sessions |-> FALSE]
    /\ ver = [f \in Folders |-> 0]
    /\ chan = [c \in Conns |-> <<>>]
    /\ view = [c \in Conns |-> [s \in Sessions |-> "none"]]
    /\ subs = [c \in Conns |-> {}]
    /\ seen = [c \in Conns |-> [f \in Folders |-> -1]]
    /\ hinted = [c \in Conns |-> {}]
    /\ refused = FALSE
    /\ badOrder = FALSE
    /\ turns = 0
    /\ changes = 0

\* session/new, session/load, or session/resume. fx sends the current state:
\* before the response to a load or resume, after the response to a new.
Open(c, s) ==
    /\ s \notin open[c] /\ ~deleted[s]
    /\ exists[s] => (saved[s] \/ Held(s))
    /\ exists' = [exists EXCEPT ![s] = TRUE]
    /\ open' = [open EXCEPT ![c] = @ \cup {s}]
    /\ chan' = [chan EXCEPT ![c] = IF Rules THEN Append(@, StateMsg(s, st[s], "none")) ELSE @]
    /\ UNCHANGED <<st, owner, saved, deleted, ver, view, subs, seen, hinted, refused, badOrder, turns, changes>>

\* session/close: the session closes on this connection only. Its response
\* comes after every message fx wrote for the session before it, so the
\* client acts on the close once it has read them.
Close(c, s) ==
    /\ s \in open[c]
    /\ \A i \in 1..Len(chan[c]) : chan[c][i].s # s
    /\ open' = [open EXCEPT ![c] = @ \ {s}]
    /\ view' = [view EXCEPT ![c][s] = "none"]
    /\ UNCHANGED <<exists, st, owner, saved, deleted, ver, chan, subs, seen, hinted,
                   refused, badOrder, turns, changes>>

\* session/prompt on an idle session starts a turn.
Prompt(c, s) ==
    /\ s \in open[c] /\ st[s] = "idle" /\ turns < MaxTurns
    /\ st' = [st EXCEPT ![s] = "running"]
    /\ owner' = [owner EXCEPT ![s] = c]
    /\ turns' = turns + 1
    /\ Write(s, "running", "none", FALSE)
    /\ UNCHANGED <<exists, open, saved, deleted, ver, view, subs, seen, hinted,
                   refused, badOrder, changes>>

\* An update of the running turn, such as a message chunk, to every
\* connection that has the session open.
Content(s) ==
    /\ st[s] = "running"
    /\ chan' = [c \in Conns |-> IF s \in open[c] THEN Append(chan[c], UpdateMsg(s)) ELSE chan[c]]
    /\ UNCHANGED <<exists, open, st, owner, saved, deleted, ver, view, subs, seen, hinted,
                   refused, badOrder, turns, changes>>

\* The turn waits for a permission answer, and goes on after it.
Block(s) ==
    /\ AllowApproval /\ st[s] = "running"
    /\ st' = [st EXCEPT ![s] = "requires_action"]
    /\ Write(s, "requires_action", "none", FALSE)
    /\ UNCHANGED <<exists, open, owner, saved, deleted, ver, view, subs, seen, hinted,
                   refused, badOrder, turns, changes>>

Unblock(s) ==
    /\ st[s] = "requires_action"
    /\ st' = [st EXCEPT ![s] = "running"]
    /\ Write(s, "running", "none", FALSE)
    /\ UNCHANGED <<exists, open, owner, saved, deleted, ver, view, subs, seen, hinted,
                   refused, badOrder, turns, changes>>

\* The turn ends and is saved, which changes its folder's list.
EndTurn(s, stop) ==
    /\ st[s] # "idle"
    /\ stop = "end_turn" => st[s] = "running"
    /\ st' = [st EXCEPT ![s] = "idle"]
    /\ owner' = [owner EXCEPT ![s] = "none"]
    /\ saved' = [saved EXCEPT ![s] = TRUE]
    /\ Bump(s)
    /\ Write(s, "idle", stop, TRUE)
    /\ UNCHANGED <<exists, open, deleted, view, subs, seen, hinted, refused, badOrder, turns, changes>>

\* The session gets a new title.
Retitle(s) ==
    /\ saved[s] /\ ~deleted[s] /\ changes < MaxChanges
    /\ changes' = changes + 1
    /\ Bump(s)
    /\ Write(s, "none", "none", TRUE)
    /\ UNCHANGED <<exists, open, st, owner, saved, deleted, view, subs, seen, hinted,
                   refused, badOrder, turns>>

\* session/delete of a saved session that no connection has open.
Delete(s) ==
    /\ saved[s] /\ ~deleted[s] /\ ~Held(s) /\ changes < MaxChanges
    /\ deleted' = [deleted EXCEPT ![s] = TRUE]
    /\ changes' = changes + 1
    /\ Bump(s)
    /\ Write(s, "none", "none", TRUE)
    /\ UNCHANGED <<exists, open, st, owner, saved, view, subs, seen, hinted, refused, badOrder, turns>>

\* session/list of one folder, or of every folder. The client then holds the
\* current version of each folder it read.
List(c, f) ==
    /\ IF ~Rules /\ Busy(c)
       THEN /\ refused' = TRUE
            /\ UNCHANGED <<subs, seen, hinted>>
       ELSE /\ subs' = [subs EXCEPT ![c] = @ \cup {f}]
            /\ seen' = [seen EXCEPT ![c] = [g \in Folders |-> IF f = All \/ f = g THEN ver[g] ELSE @[g]]]
            /\ hinted' = [hinted EXCEPT ![c] = IF f = All THEN {} ELSE @ \ {f}]
            /\ refused' = FALSE
    /\ UNCHANGED <<exists, open, st, owner, saved, deleted, ver, chan, view, badOrder, turns, changes>>

\* What session/status should answer for session s.
Truth(s) ==
    IF ~exists[s] \/ deleted[s] \/ (~saved[s] /\ ~Held(s))
    THEN [kind |-> "unknown", status |-> "none", state |-> "none"]
    ELSE [kind |-> "ok", status |-> IF Held(s) THEN "open" ELSE "saved",
          state |-> IF Held(s) THEN st[s] ELSE "none"]

\* What fx answers.
Answer(c, s) ==
    IF Rules THEN Truth(s)
    ELSE [kind |-> IF Busy(c) THEN "busy" ELSE "no_method", status |-> "none", state |-> "none"]

\* The client reads the next message fx wrote to it.
Deliver(c) ==
    /\ chan[c] # <<>>
    /\ LET m == Head(chan[c]) IN
       /\ chan' = [chan EXCEPT ![c] = Tail(@)]
       /\ view' = IF m.kind = "state" /\ m.s \in open[c] THEN [view EXCEPT ![c][m.s] = m.state] ELSE view
       /\ hinted' = IF m.kind = "hint" THEN [hinted EXCEPT ![c] = @ \cup {m.f}] ELSE hinted
       /\ badOrder' = (badOrder \/ (m.kind = "update" /\ m.s \in open[c]
                                    /\ view[c][m.s] \notin {"running", "requires_action"}))
    /\ UNCHANGED <<exists, open, st, owner, saved, deleted, ver, subs, seen, refused,
                   turns, changes>>

Next ==
    \/ \E c \in Conns, s \in Sessions : Open(c, s) \/ Close(c, s) \/ Prompt(c, s)
    \/ \E s \in Sessions : Content(s) \/ Block(s) \/ Unblock(s) \/ Retitle(s) \/ Delete(s)
    \/ \E s \in Sessions, stop \in {"end_turn", "cancelled"} : EndTurn(s, stop)
    \/ \E c \in Conns, f \in Folders \cup {All} : List(c, f)
    \/ \E c \in Conns : Deliver(c)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ st \in [Sessions -> States]
    /\ \A c \in Conns : open[c] \subseteq Sessions
    /\ \A c \in Conns, s \in Sessions : view[c][s] \in States \cup {"none"}

PendingState(c, s) == \E i \in 1..Len(chan[c]) : chan[c][i].kind = "state" /\ chan[c][i].s = s
PendingHint(c, f) == \E i \in 1..Len(chan[c]) : chan[c][i].kind = "hint" /\ chan[c][i].f = f

\* A connection's view of a session's state is current once no state is on its way.
StateCurrent ==
    \A c \in Conns, s \in Sessions :
        (s \in open[c] /\ ~PendingState(c, s)) => view[c][s] = st[s]

\* No update of a turn reaches a client that thinks the session isn't running.
UpdatesWhileRunning == ~badOrder

\* Only idle carries a stopReason.
IdleCarriesStop ==
    \A c \in Conns : \A i \in 1..Len(chan[c]) :
        (chan[c][i].kind = "state" /\ chan[c][i].state # "idle") => chan[c][i].stop = "none"

\* A list a client holds is out of date only while a hint is on its way, or
\* after the client read one and before it lists the folder again.
ListFresh ==
    \A c \in Conns, f \in Folders :
        (Covers(c, f) /\ seen[c][f] < ver[f]) => (f \in hinted[c] \/ PendingHint(c, f))

\* session/list is never refused (X24).
ListAnswered == ~refused

\* A session/status request that any connection sends now gets what is true.
\* fx's answer depends only on the current state, so checking it in every
\* state checks every request.
StatusTruthful == \A c \in Conns, s \in Sessions : Answer(c, s) = Truth(s)
=============================================================================
