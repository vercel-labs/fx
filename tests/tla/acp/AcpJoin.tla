------------------------------ MODULE AcpJoin -------------------------------
(***************************************************************************)
(* The join of a second connection to a session that another connection of *)
(* the same process has open, as the sh.fx spec's "Following a session"    *)
(* section sets it out (src/protocol/spec/sh-fx.md), and as src/acp/       *)
(* sessions.zig and src/acp/server.zig carry it out.                       *)
(*                                                                         *)
(* - A session can be open on several connections of one process. A        *)
(*   connection that sends session/load or session/resume for a session    *)
(*   another connection has open joins it.                                 *)
(* - A load replays the saved turns, then the running turn's kept updates, *)
(*   then a notice when the copy dropped any, then the answer. A resume    *)
(*   gives only the answer. After its answer, a joined connection gets     *)
(*   each update once, in order.                                           *)
(* - The running copy keeps the running turn's updates in order, up to     *)
(*   its limit. After it drops one, it keeps no later one. Saving the      *)
(*   turn commits it to the log and frees the copy in the same step.       *)
(* - The turn's end sends its tail through the copy, and the copy is freed *)
(*   when the turn's end finishes. A load gets a tail from the copy while  *)
(*   the copy holds it.                                                    *)
(* - A joined connection that closes the session, or ends, leaves the      *)
(*   audience. A follower's mode or config request is refused and changes  *)
(*   nothing; its hooks change is ignored. Its systemPrompt applies from    *)
(*   the next turn, as an owner's does; AcpSystemPrompt models that.        *)
(*   A follower's prompt is not here. It enters the session's one input    *)
(*   order (sh-fx.md, Following a session); this spec does not model it.   *)
(* - With Rules = FALSE (fx before the join), a second connection's        *)
(*   load is refused as busy, so no connection joins.                      *)
(*                                                                         *)
(* One tail item stands for a turn's title and usage updates. The title is *)
(* sent by sendSessionInfoUpdate (sessions.zig), and the usage update is   *)
(* built in types.zig. The usage update may be absent: prompt.zig sends    *)
(* none for a turn whose completions report no tokens. The model counts    *)
(* one unit per update. fx counts bytes against the copy's limit. Every    *)
(* joiner takes every kept update; the per-connection capability filter is *)
(* outside this model. The join's saved-title update is not modelled. A    *)
(* repeat load and a load after a close are not modelled. A load replays a *)
(* saved turn's messages without its tail (sendHistoryTurnAsUpdates in     *)
(* sessions.zig), so a joiner gets no earlier tail.                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Joiners,    \* the other connections of the process that may join
    MaxTurns,   \* the turns the model runs, one after another
    MaxSends,   \* the updates a turn sends before it ends
    Limit,      \* the running copy's capacity, in updates
    Rules       \* TRUE: fx joins; FALSE: before the join, a load is refused

\* The join's answer and the notice are messages of no turn (t = 0), so every
\* message in a joiner's sequence is a record of two integers.
Ans == [t |-> 0, k |-> 0]      \* the join's answer, written after the replay
Note == [t |-> 0, k |-> 1]     \* the notice that the copy dropped an update

VARIABLES
    turn,       \* the current or last turn's number
    phase,      \* "idle", "running", "saved" (tail not sent), or "ending"
    sent,       \* the updates the running turn has sent
    runItems,   \* ghost: the updates the running turn has sent, in order
    copy,       \* the running copy: the updates it keeps, in order
    dropped,    \* the copy has dropped an update, so it keeps no more
    log,        \* ghost: the saved turns' updates in order, without tails
    owner,      \* every update the owner's connection received, in order
    joiner,     \* per joiner: "out", "loaded", "resumed", or "closed"
    got,        \* per joiner: every message its connection received, in order
    mark,       \* per joiner: the owner's length when it joined
    skip,       \* ghost: per joiner: the owner's updates it is not sent
    closedLen,  \* ghost: per joiner: the length of got when it closed
    early,      \* ghost: per joiner: an update reached it before its answer
    changed     \* ghost: a follower changed the session

vars == <<turn, phase, sent, runItems, copy, dropped, log, owner, joiner,
          got, mark, skip, closedLen, early, changed>>

\* The tail a turn sends at its end. One item stands for its title and its
\* usage updates, which the code sends in turn (prompt.zig:1552-1553;
\* sendToAudience, sessions.zig:2278 and :2325); the usage one may be absent.
\* It is numbered after the turn's updates, so every item is a pair of integers.
TailItem(t) == [t |-> t, k |-> MaxSends + 1]

\* The items the model can hold: the turn's updates and its tail.
Items == {[t |-> t, k |-> k] : t \in 1..MaxTurns, k \in 1..(MaxSends + 1)}

\* The update the running turn sends next.
SendItem == [t |-> turn, k |-> sent + 1]

\* A joined connection gets every update: a loaded or a resumed one.
Audience(j) == joiner[j] \in {"loaded", "resumed"}

\* The copy keeps the next update while it has room and has dropped none.
Keeps == ~dropped /\ Len(copy) < Limit

\* What a join records as missed: the turn's updates the copy did not keep.
MissedAtJoin ==
    IF phase = "running" THEN SubSeq(runItems, Len(copy) + 1, Len(runItems))
    ELSE <<>>

\* The sequence s without the members of the set drop, in order.
RECURSIVE Keep(_, _)
Keep(s, drop) ==
    IF s = <<>> THEN <<>>
    ELSE IF Head(s) \in drop THEN Keep(Tail(s), drop)
    ELSE <<Head(s)>> \o Keep(Tail(s), drop)

\* The members of the sequence s.
Range(s) == {s[i] : i \in DOMAIN s}

\* What a connection holds of the updates, without its answer and its notice.
Visible(s) == Keep(s, {Ans, Note})

\* What a join does not send from the owner's updates: the running turn's
\* updates its copy did not keep, and every tail in the owner that the copy no
\* longer holds. A load replays a saved turn's messages without its tail
\* (sessions.zig:1791), and a tail the copy still holds is replayed from it.
SkipAtJoin ==
    Range(MissedAtJoin) \cup (({TailItem(t) : t \in 1..turn} \cap Range(owner)) \ Range(copy))

Init ==
    /\ turn = 0
    /\ phase = "idle"
    /\ sent = 0
    /\ runItems = <<>>
    /\ copy = <<>>
    /\ dropped = FALSE
    /\ log = <<>>
    /\ owner = <<>>
    /\ joiner = [j \in Joiners |-> "out"]
    /\ got = [j \in Joiners |-> <<>>]
    /\ mark = [j \in Joiners |-> 0]
    /\ skip = [j \in Joiners |-> {}]
    /\ closedLen = [j \in Joiners |-> 0]
    /\ early = [j \in Joiners |-> FALSE]
    /\ changed = FALSE

\* A turn starts: the session's prompt is set (server.zig:3447, startPrompt).
Start ==
    /\ phase = "idle"
    /\ turn < MaxTurns
    /\ turn' = turn + 1
    /\ phase' = "running"
    /\ sent' = 0
    /\ runItems' = <<>>
    /\ copy' = <<>>
    /\ dropped' = FALSE
    /\ UNCHANGED <<log, owner, joiner, got, mark, skip, closedLen, early, changed>>

\* The running turn sends an update: the owner and every joined connection get
\* it, and the copy keeps it while it has room (server.zig:1018-1027,
\* Audience.deliver; server.zig:1158, RunningCopy.add).
Send ==
    /\ phase = "running"
    /\ sent < MaxSends
    /\ sent' = sent + 1
    /\ runItems' = Append(runItems, SendItem)
    /\ owner' = Append(owner, SendItem)
    /\ got' = [j \in Joiners |-> IF Audience(j) THEN Append(got[j], SendItem) ELSE got[j]]
    /\ early' = [j \in Joiners |-> early[j] \/ (joiner[j] = "listed" /\ Audience(j))]
    /\ copy' = IF Keeps THEN Append(copy, SendItem) ELSE copy
    /\ dropped' = (dropped \/ ~Keeps)
    /\ UNCHANGED <<turn, phase, log, joiner, mark, skip, closedLen, changed>>

\* The turn is saved: the log takes its updates, and the copy is freed in the
\* same step (prompt.zig:3518, persistAcpHistoryTurn, with releases_copy;
\* server.zig:1238, releaseRunningCopy).
Save ==
    /\ phase = "running"
    /\ phase' = "saved"
    /\ log' = log \o runItems
    /\ copy' = <<>>
    /\ dropped' = FALSE
    /\ UNCHANGED <<turn, sent, runItems, owner, joiner, got, mark, skip, closedLen, early, changed>>

\* The turn's end sends its tail: the owner and every joined connection get it,
\* and the copy keeps it under the same rule as Send (prompt.zig:1552-1553,
\* sendToAudience; server.zig:1018-1027, Audience.deliver; server.zig:1158,
\* RunningCopy.add).
SendTail ==
    /\ phase = "saved"
    /\ phase' = "ending"
    /\ owner' = Append(owner, TailItem(turn))
    /\ got' = [j \in Joiners |-> IF Audience(j) THEN Append(got[j], TailItem(turn)) ELSE got[j]]
    /\ early' = [j \in Joiners |-> early[j] \/ (joiner[j] = "listed" /\ Audience(j))]
    /\ copy' = IF Keeps THEN Append(copy, TailItem(turn)) ELSE copy
    /\ dropped' = (dropped \/ ~Keeps)
    /\ UNCHANGED <<turn, sent, runItems, log, joiner, mark, skip, closedLen, changed>>

\* The turn's end frees its copy, so the tail is no longer replayed from it
\* (server.zig:3648, promptWorkerMain's release).
Release ==
    /\ phase = "ending"
    /\ phase' = "idle"
    /\ copy' = <<>>
    /\ dropped' = FALSE
    /\ runItems' = <<>>
    /\ UNCHANGED <<turn, sent, log, owner, joiner, got, mark, skip, closedLen, early, changed>>

\* A connection loads a session another connection has open. It gets the saved
\* turns' messages without their tails, the copy (which holds the turn's tail
\* until the release), a notice if the copy dropped an update, and the answer,
\* in one step under session_write_mutex and audience_mutex (sessions.zig:830,
\* joinSession; server.zig:1385, replayRunningCopy). Refused when Rules is FALSE
\* (server.zig:419, the second store fails as busy).
Load(j) ==
    /\ Rules
    /\ joiner[j] = "out"
    /\ joiner' = [joiner EXCEPT ![j] = "loaded"]
    /\ got' = [got EXCEPT ![j] = log \o copy \o (IF dropped THEN <<Note>> ELSE <<>>) \o <<Ans>>]
    /\ mark' = [mark EXCEPT ![j] = Len(owner)]
    /\ skip' = [skip EXCEPT ![j] = SkipAtJoin]
    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, closedLen, early, changed>>

\* A connection resumes a session another connection has open: it gets the
\* answer and the updates from now on, with no replay (sessions.zig:830,
\* joinSession, which takes audience_mutex only for a resume).
Resume(j) ==
    /\ Rules
    /\ joiner[j] = "out"
    /\ joiner' = [joiner EXCEPT ![j] = "resumed"]
    /\ got' = [got EXCEPT ![j] = <<Ans>>]
    /\ mark' = [mark EXCEPT ![j] = Len(owner)]
    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, skip, closedLen, early, changed>>

\* A joined connection closes the session, or ends: it leaves the audience
\* (server.zig:4915, handleCloseSession; server.zig:1471, detachFollower).
Close(j) ==
    /\ Audience(j)
    /\ joiner' = [joiner EXCEPT ![j] = "closed"]
    /\ closedLen' = [closedLen EXCEPT ![j] = Len(got[j])]
    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, got, mark, skip, early, changed>>

\* A joined connection sends the session a mode or a config option. fx refuses
\* each one, and it changes nothing (server.zig:3959,
\* requireParsedSessionTarget). A joined connection's hooks change is ignored
\* and changes nothing (sessions.zig:813, traceIgnoredFollowerHooks). Its
\* systemPrompt is not modeled here: it applies from the next turn
\* (sessions.zig:802, commitClientSystemPrompt). A follower's prompt is not a
\* change here: it enters the session's one input order (sh-fx.md, "Following
\* a session"), which this spec does not model.
FollowerChange(j) ==
    /\ Audience(j)
    /\ changed' = changed
    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, joiner, got, mark, skip, closedLen, early>>

Next ==
    \/ Start
    \/ Send
    \/ Save
    \/ SendTail
    \/ Release
    \/ \E j \in Joiners :
        \/ Load(j)
        \/ Resume(j)
        \/ Close(j)
        \/ FollowerChange(j)

\* Weak fairness: a joiner that may load does so.
Spec == Init /\ [][Next]_vars /\ \A j \in Joiners : WF_vars(Load(j))

-----------------------------------------------------------------------------
\* Forbids a variable outside its type.
TypeOK ==
    /\ turn \in 0..MaxTurns
    /\ phase \in {"idle", "running", "saved", "ending"}
    /\ sent \in 0..MaxSends
    /\ dropped \in BOOLEAN
    /\ changed \in BOOLEAN
    /\ joiner \in [Joiners -> {"out", "loaded", "resumed", "closed"}]
    /\ early \in [Joiners -> BOOLEAN]
    /\ mark \in [Joiners -> Nat]
    /\ closedLen \in [Joiners -> Nat]
    /\ owner \in Seq(Items)
    /\ log \in Seq(Items)
    /\ runItems \in Seq(Items)
    /\ copy \in Seq(Items)
    /\ got \in [Joiners -> Seq(Items \cup {Ans, Note})]
    /\ skip \in [Joiners -> SUBSET Items]

\* Forbids a loaded connection's gaps, repeats, or misplaced notice.
LoadSeesAll ==
    \A j \in Joiners :
        joiner[j] = "loaded" =>
            (Visible(got[j]) = Keep(owner, skip[j])
             /\ \A i \in DOMAIN got[j] :
                    got[j][i] = Note => (i + 1 \in DOMAIN got[j] /\ got[j][i + 1] = Ans))

\* Forbids a resumed connection's old updates, or a missed live one.
ResumeSeesLive ==
    \A j \in Joiners :
        joiner[j] = "resumed" => Visible(got[j]) = SubSeq(owner, mark[j] + 1, Len(owner))

\* Forbids an update that reaches a connection before its answer.
AnswerFirst == \A j \in Joiners : ~early[j]

\* Forbids a closed connection that gets anything after it closed.
ClosedGetsNothing == \A j \in Joiners : joiner[j] = "closed" => Len(got[j]) = closedLen[j]

\* A follower's refused mode or config request, and its ignored hooks, change
\* nothing. Its system prompt applies from the next turn and is outside this
\* property.
RefusedFollowerChangeChangesNothing == ~changed

\* Forbids a running copy that holds more updates than its limit.
CopyBounded == Len(copy) <= Limit

\* Forbids a running copy that lacks an update without marking it dropped.
DropIsNoted == phase = "running" => (Len(copy) < Len(runItems) => dropped)

\* Forbids a run in which no connection that asks to join ever gets its answer.
JoinWorks == <>(\E j \in Joiners : joiner[j] \in {"loaded", "resumed"})

=============================================================================
