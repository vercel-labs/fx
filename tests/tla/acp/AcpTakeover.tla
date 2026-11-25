--------------------------- MODULE AcpTakeover ---------------------------
(***************************************************************************)
(* What happens to one session when the fx acp process that holds its lock  *)
(* dies, and how the next process takes the session over.                   *)
(*                                                                          *)
(* Rules (the names are used by the planted bugs in check.sh):              *)
(* - Lock only: at most one process holds the session's lock, and a process *)
(*   that does not hold it never writes the lock line, or a folder or socket *)
(*   that is not its own.                                                   *)
(* - Dead holder: a killed holder loses the lock at once, its line and its  *)
(*   folder stay, and no process in its memory is kept.                     *)
(* - Takeover: the next process that loads and wins the lock repairs a      *)
(*   running turn as interrupted, and starts no model call that no client   *)
(*   asked for. It restores no grant and no queued prompt. It releases the   *)
(*   lock only after the repair and the folder cleanup, as its open does.    *)
(* - Folder cleanup (design A, built): the next holder removes the folder   *)
(*   of a dead holder only when the folder's connect is refused and its pid *)
(*   is gone. A timeout or a live process keeps the folder. The holder      *)
(*   removes it before it writes its own line.                              *)
(* - Two loaders after a death: one wins the lock, the other is busy.       *)
(* - A follower whose socket closed loads again and gets a new connection.   *)
(*                                                                          *)
(* `today` is the code before the takeover change: no folder cleanup, and   *)
(* the holder writes its line at once. Every rule except folder cleanup     *)
(* must hold there. It stays as the control for that change.                *)
(* The planted mutations each break one rule and name it (see check.sh).     *)
(*                                                                          *)
(* Scope: one session, one client, one follower, one death, at most two      *)
(* asks for a turn. A process exits cleanly only after it has loaded the     *)
(* session and is not waiting for the lock, so a loader never leaves before  *)
(* it can take the lock.                                                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Procs,      \* the fx acp processes; a holder may die once, the rest load
    MaxAsks,    \* the client's asks for a turn
    Mutation    \* "none" is the design; "today" and the planted bugs below

NoProc == "no process"

ASSUME MaxAsks \in Nat \ {0}
ASSUME Mutation \in {"none", "today", "remove_live", "remove_no_lock",
                     "remove_on_timeout", "two_holders", "restore_grant",
                     "restore_queue", "restore_question", "continue_turn",
                     "line_by_other"}

VARIABLES
    st,            \* "new", "alive", "dead" (killed), "gone" (exited cleanly)
    sock,          \* the process's leader socket listens
    folder,        \* "none", "made", "gone": the process's socket folder
    reused,        \* the dead process's pid now belongs to another process
    holders,       \* the processes that hold the session's lock
    line,          \* the process the lock line names, or NoProc
    loading,       \* the process is loading the session, waiting for the lock
    asked,         \* the process has loaded the session once
    busyOut,       \* the process's load ended busy
    grant,         \* the holder has an "allow for this session" grant
    grantOwner,    \* the process that made the grant
    queue,         \* the holder has a queued prompt (0 or 1)
    queueOwner,    \* the process that queued it
    question,      \* the holder has a permission question open
    questionOwner, \* the process whose turn asked the question
    turn,          \* "none", "running", "committed", "interrupted"
    turnOwner,     \* the process that started the turn
    calls,         \* model calls started
    asks,          \* turns a client asked for
    fol,           \* the follower: "none", "connected", "closed"
    folConn,       \* the process the follower is connected to
    crashes,       \* the number of deaths so far (at most one)
    okLine,        \* ghost: every write of the lock line was by a holder
    okFolder,      \* ghost: every removal of a folder was by a holder
    removedLive,   \* ghost: a folder was removed while its process was alive
    removedTimeout \* ghost: a folder was removed after a probe timeout

procVars  == <<st, sock, folder, reused>>
lockVars  == <<holders, line>>
loadVars  == <<loading, asked, busyOut>>
memVars   == <<grant, grantOwner, queue, queueOwner, question, questionOwner>>
turnVars  == <<turn, turnOwner, calls, asks>>
folVars   == <<fol, folConn>>
ghostVars == <<crashes, okLine, okFolder, removedLive, removedTimeout>>
vars      == <<procVars, lockVars, loadVars, memVars, turnVars, folVars, ghostVars>>

Live(p) == st[p] = "alive"
Gone(p) == st[p] \in {"dead", "gone"}

\* The next holder may remove the folder that the lock line names: the
\* process it names is dead, its socket refuses, its pid is gone, and its
\* folder is still there. Only a process other than the holder is named.
Cleanable(h) ==
    \E q \in Procs :
        /\ line = q /\ q # h
        /\ folder[q] = "made" /\ st[q] = "dead"
        /\ ~sock[q] /\ ~reused[q]

Init ==
    /\ st = [p \in Procs |-> "new"]
    /\ sock = [p \in Procs |-> FALSE]
    /\ folder = [p \in Procs |-> "none"]
    /\ reused = [p \in Procs |-> FALSE]
    /\ holders = {}
    /\ line = NoProc
    /\ loading = [p \in Procs |-> FALSE]
    /\ asked = [p \in Procs |-> FALSE]
    /\ busyOut = [p \in Procs |-> FALSE]
    /\ grant = FALSE
    /\ grantOwner = NoProc
    /\ queue = 0
    /\ queueOwner = NoProc
    /\ question = FALSE
    /\ questionOwner = NoProc
    /\ turn = "none"
    /\ turnOwner = NoProc
    /\ calls = 0
    /\ asks = 0
    /\ fol = "none"
    /\ folConn = NoProc
    /\ crashes = 0
    /\ okLine = TRUE
    /\ okFolder = TRUE
    /\ removedLive = FALSE
    /\ removedTimeout = FALSE

-----------------------------------------------------------------------------
\* A process starts: it makes its folder and listens, before any session.
Start(p) ==
    /\ st[p] = "new"
    /\ st' = [st EXCEPT ![p] = "alive"]
    /\ sock' = [sock EXCEPT ![p] = TRUE]
    /\ folder' = [folder EXCEPT ![p] = "made"]
    /\ UNCHANGED <<reused, lockVars, loadVars, memVars, turnVars, folVars, ghostVars>>

\* A client loads the session on a live process, once.
Load(p) ==
    /\ Live(p) /\ ~asked[p]
    /\ asked' = [asked EXCEPT ![p] = TRUE]
    /\ loading' = [loading EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<procVars, lockVars, busyOut, memVars, turnVars, folVars, ghostVars>>

\* A loader wins the lock. The new holder starts with no grant and no queued
\* prompt: they lived in the old holder's memory.
Take(p) ==
    /\ Live(p) /\ loading[p] /\ sock[p]
    /\ (holders = {} \/ Mutation = "two_holders")
    /\ holders' = holders \cup {p}
    /\ loading' = [loading EXCEPT ![p] = FALSE]
    /\ grant' = IF Mutation = "restore_grant" THEN grant ELSE FALSE
    /\ grantOwner' = IF Mutation = "restore_grant" THEN grantOwner ELSE NoProc
    /\ queue' = IF Mutation = "restore_queue" THEN queue ELSE 0
    /\ queueOwner' = IF Mutation = "restore_queue" THEN queueOwner ELSE NoProc
    /\ question' = IF Mutation = "restore_question" THEN question ELSE FALSE
    /\ questionOwner' = IF Mutation = "restore_question" THEN questionOwner ELSE NoProc
    /\ UNCHANGED <<procVars, line, asked, busyOut, turnVars, folVars, ghostVars>>

\* A loader finds the lock held and ends busy. Time is not modeled: the
\* loader waits its bounded time, and the lock is still held.
Busy(p) ==
    /\ Live(p) /\ loading[p] /\ holders # {} /\ p \notin holders
    /\ loading' = [loading EXCEPT ![p] = FALSE]
    /\ busyOut' = [busyOut EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<procVars, lockVars, asked, memVars, turnVars, folVars, ghostVars>>

\* The holder is killed. Its lock is released at once; its line, its folder
\* and its socket-folder pid stay. Its socket stops answering.
Crash(p) ==
    /\ crashes = 0 /\ p \in holders /\ Live(p)
    /\ st' = [st EXCEPT ![p] = "dead"]
    /\ sock' = [sock EXCEPT ![p] = FALSE]
    /\ \E r \in BOOLEAN : reused' = [reused EXCEPT ![p] = r]
    /\ holders' = holders \ {p}
    /\ fol' = IF folConn = p THEN "closed" ELSE fol
    /\ folConn' = IF folConn = p THEN NoProc ELSE folConn
    /\ crashes' = 1
    /\ UNCHANGED <<folder, line, loadVars, memVars, turnVars, okLine, okFolder,
                   removedLive, removedTimeout>>

\* A process that holds no lock exits cleanly: it removes its own folder and
\* socket. Its socket's clients are closed.
Exit(p) ==
    /\ Live(p) /\ p \notin holders /\ asked[p] /\ ~loading[p]
    /\ st' = [st EXCEPT ![p] = "gone"]
    /\ sock' = [sock EXCEPT ![p] = FALSE]
    /\ folder' = [folder EXCEPT ![p] = "gone"]
    /\ \E r \in BOOLEAN : reused' = [reused EXCEPT ![p] = r]
    /\ fol' = IF folConn = p THEN "closed" ELSE fol
    /\ folConn' = IF folConn = p THEN NoProc ELSE folConn
    /\ UNCHANGED <<lockVars, loadVars, memVars, turnVars, crashes, okLine,
                   okFolder, removedLive, removedTimeout>>

\* The unrelated process that took the dead pid exits.
PidFree(p) ==
    /\ reused[p] /\ Gone(p)
    /\ reused' = [reused EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<st, sock, folder, lockVars, loadVars, memVars, turnVars,
                   folVars, ghostVars>>

\* The holder writes its own line, once its socket listens, unless the
\* folder of a dead process is still there to remove first.
Write(h) ==
    /\ h \in holders /\ sock[h] /\ line # h
    /\ (Mutation = "today" \/ ~Cleanable(h))
    /\ line' = h
    /\ UNCHANGED <<procVars, holders, loadVars, memVars, turnVars, folVars, ghostVars>>

\* The holder clears its own line before it unlocks.
Clear(h) ==
    /\ h \in holders /\ line = h
    /\ line' = NoProc
    /\ UNCHANGED <<procVars, holders, loadVars, memVars, turnVars, folVars, ghostVars>>

\* The holder unlocks once its line is clear, and its memory goes with it.
Unlock(h) ==
    /\ h \in holders /\ line # h
    /\ ~(turn = "running" /\ turnOwner = h)
    /\ ~(turn = "running" /\ st[turnOwner] = "dead")
    /\ (Mutation = "today" \/ ~Cleanable(h))
    /\ holders' = holders \ {h}
    /\ grant' = FALSE /\ grantOwner' = NoProc
    /\ queue' = 0 /\ queueOwner' = NoProc
    /\ question' = FALSE /\ questionOwner' = NoProc
    /\ UNCHANGED <<procVars, line, loadVars, turnVars, folVars, ghostVars>>

\* The clear of the line fails, and the holder unlocks anyway. The line
\* still names it, and it stays alive. (fx keeps the content and traces it.)
UnclearedRelease(h) ==
    /\ h \in holders /\ line = h
    /\ ~(turn = "running" /\ turnOwner = h)
    /\ ~(turn = "running" /\ st[turnOwner] = "dead")
    /\ (Mutation = "today" \/ ~Cleanable(h))
    /\ holders' = holders \ {h}
    /\ grant' = FALSE /\ grantOwner' = NoProc
    /\ queue' = 0 /\ queueOwner' = NoProc
    /\ question' = FALSE /\ questionOwner' = NoProc
    /\ UNCHANGED <<procVars, line, loadVars, turnVars, folVars, ghostVars>>

\* The holder removes the folder of a dead process that its line names. It
\* does this before it writes its own line. Not in the today config.
Clean(h, q) ==
    /\ Mutation # "today"
    /\ h \in holders /\ line = q /\ q # h
    /\ folder[q] = "made" /\ st[q] = "dead" /\ ~sock[q] /\ ~reused[q]
    /\ folder' = [folder EXCEPT ![q] = "gone"]
    /\ UNCHANGED <<st, sock, reused, lockVars, loadVars, memVars, turnVars,
                   folVars, ghostVars>>

\* The running turn of the holder asks a permission question.
Ask(h) ==
    /\ h \in holders /\ Live(h) /\ turn = "running" /\ turnOwner = h
    /\ ~question
    /\ question' = TRUE /\ questionOwner' = h
    /\ UNCHANGED <<procVars, lockVars, loadVars, grant, grantOwner, queue, queueOwner,
                   turnVars, folVars, ghostVars>>

\* The client answers the holder's question.
Answer(h) ==
    /\ h \in holders /\ Live(h) /\ question /\ questionOwner = h
    /\ question' = FALSE /\ questionOwner' = NoProc
    /\ UNCHANGED <<procVars, lockVars, loadVars, grant, grantOwner, queue, queueOwner,
                   turnVars, folVars, ghostVars>>

\* The holder's first turn: a client asked for it.
StartTurn(h) ==
    /\ h \in holders /\ Live(h)
    /\ turn \in {"none", "committed", "interrupted"}
    /\ asks < MaxAsks
    /\ turn' = "running" /\ turnOwner' = h
    /\ asks' = asks + 1 /\ calls' = calls + 1
    /\ UNCHANGED <<procVars, lockVars, loadVars, memVars, folVars, ghostVars>>

\* The running turn finishes and is committed.
Commit(h) ==
    /\ h \in holders /\ Live(h) /\ turn = "running" /\ turnOwner = h
    /\ turn' = "committed" /\ queue' = 0 /\ queueOwner' = NoProc
    /\ UNCHANGED <<procVars, lockVars, loadVars, grant, grantOwner, turnOwner,                    calls, asks, folVars, ghostVars, question, questionOwner>>

\* The holder may allow the session once. The grant is in its memory.
GrantAsk(h) ==
    /\ h \in holders /\ ~grant /\ Live(h)
    /\ grant' = TRUE /\ grantOwner' = h
    /\ UNCHANGED <<procVars, lockVars, loadVars, queue, queueOwner, question,
                   questionOwner, turnVars, folVars, ghostVars>>

\* A prompt is queued behind the running turn, in the holder's memory.
Enqueue(h) ==
    /\ h \in holders /\ turn = "running" /\ turnOwner = h /\ queue = 0
    /\ queue' = 1 /\ queueOwner' = h
    /\ UNCHANGED <<procVars, lockVars, loadVars, grant, grantOwner, turnVars,                    folVars, ghostVars, question, questionOwner>>

\* The next holder repairs a turn whose owner died: it is interrupted, and no
\* model call starts. (continue_turn: the repair continues it by itself.)
Repair(h) ==
    /\ h \in holders /\ turn = "running" /\ st[turnOwner] = "dead"
    /\ IF Mutation = "continue_turn"
       THEN /\ turn' = "running" /\ turnOwner' = h /\ calls' = calls + 1
       ELSE /\ turn' = "interrupted" /\ turnOwner' = turnOwner /\ calls' = calls
    /\ UNCHANGED <<procVars, lockVars, loadVars, memVars, asks, folVars, ghostVars>>

\* A follower connects to a holder whose socket listens.
Connect ==
    /\ fol \in {"none", "closed"} /\ holders # {}
    /\ \E h \in holders :
        /\ sock[h]
        /\ fol' = "connected" /\ folConn' = h
    /\ UNCHANGED <<procVars, lockVars, loadVars, memVars, turnVars, ghostVars>>

-----------------------------------------------------------------------------
\* Planted bugs. Each is one broken rule, and check.sh names the property
\* that catches it.

\* Remove the folder of the live holder itself, after its line names it.
RemoveLive(h) ==
    /\ Mutation = "remove_live"
    /\ h \in holders /\ line = h /\ folder[h] = "made"
    /\ folder' = [folder EXCEPT ![h] = "gone"]
    /\ removedLive' = TRUE
    /\ UNCHANGED <<st, sock, reused, lockVars, loadVars, memVars, turnVars, folVars,
                   crashes, okLine, okFolder, removedTimeout>>

\* Remove a dead process's folder from a process that holds no lock.
RemoveNoLock(p, q) ==
    /\ Mutation = "remove_no_lock"
    /\ Live(p) /\ p \notin holders
    /\ line = q /\ q # p
    /\ folder[q] = "made" /\ st[q] = "dead" /\ ~sock[q] /\ ~reused[q]
    /\ folder' = [folder EXCEPT ![q] = "gone"]
    /\ okFolder' = FALSE
    /\ UNCHANGED <<st, sock, reused, lockVars, loadVars, memVars, turnVars, folVars,
                   crashes, okLine, removedLive, removedTimeout>>

\* Remove a folder whose process is alive but whose probe timed out.
RemoveOnTimeout(h, q) ==
    /\ Mutation = "remove_on_timeout"
    /\ h \in holders /\ line = q /\ q # h
    /\ folder[q] = "made" /\ st[q] = "alive" /\ sock[q]
    /\ folder' = [folder EXCEPT ![q] = "gone"]
    /\ removedTimeout' = TRUE
    /\ UNCHANGED <<st, sock, reused, lockVars, loadVars, memVars, turnVars, folVars,
                   crashes, okLine, okFolder, removedLive>>

\* A process that holds no lock empties the lock line.
ClearByOther(p) ==
    /\ Mutation = "line_by_other"
    /\ Live(p) /\ p \notin holders /\ line # NoProc
    /\ line' = NoProc /\ okLine' = FALSE
    /\ UNCHANGED <<procVars, holders, loadVars, memVars, turnVars, folVars,
                   crashes, okFolder, removedLive, removedTimeout>>

-----------------------------------------------------------------------------
Next ==
    \/ \E p \in Procs :
        \/ Start(p) \/ Load(p) \/ Take(p) \/ Busy(p) \/ Crash(p)
        \/ Exit(p) \/ PidFree(p) \/ Write(p) \/ Clear(p) \/ Unlock(p)
        \/ UnclearedRelease(p) \/ StartTurn(p) \/ Commit(p) \/ GrantAsk(p)
        \/ Enqueue(p) \/ Repair(p) \/ RemoveLive(p) \/ ClearByOther(p)
        \/ Ask(p) \/ Answer(p)
        \/ \E q \in Procs :
            \/ Clean(p, q) \/ RemoveNoLock(p, q) \/ RemoveOnTimeout(p, q)
    \/ Connect

\* Weak fairness: a loader that can take the lock does, and a finished
\* repair, cleanup and pid change happen. Crashes are not forced.
Fairness ==
    /\ \A p \in Procs : WF_vars(Load(p)) /\ WF_vars(Take(p)) /\ WF_vars(Busy(p))
    /\ \A p \in Procs : WF_vars(Repair(p)) /\ WF_vars(PidFree(p))
    /\ \A h, q \in Procs : WF_vars(Clean(h, q))

Spec == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Safety: each invariant names the rule it checks.

TypeOK ==
    /\ st \in [Procs -> {"new", "alive", "dead", "gone"}]
    /\ sock \in [Procs -> BOOLEAN]
    /\ folder \in [Procs -> {"none", "made", "gone"}]
    /\ reused \in [Procs -> BOOLEAN]
    /\ holders \subseteq Procs
    /\ line \in Procs \cup {NoProc}
    /\ loading \in [Procs -> BOOLEAN] /\ asked \in [Procs -> BOOLEAN]
    /\ busyOut \in [Procs -> BOOLEAN]
    /\ grant \in BOOLEAN /\ grantOwner \in Procs \cup {NoProc}
    /\ queue \in 0..1 /\ queueOwner \in Procs \cup {NoProc}
    /\ question \in BOOLEAN /\ questionOwner \in Procs \cup {NoProc}
    /\ turn \in {"none", "running", "committed", "interrupted"}
    /\ turnOwner \in Procs \cup {NoProc}
    /\ calls \in 0..(MaxAsks + 1) /\ asks \in 0..MaxAsks
    /\ fol \in {"none", "connected", "closed"} /\ folConn \in Procs \cup {NoProc}
    /\ crashes \in 0..1
    /\ okLine \in BOOLEAN /\ okFolder \in BOOLEAN
    /\ removedLive \in BOOLEAN /\ removedTimeout \in BOOLEAN

\* Lock only: at most one process holds the session.
AtMostOneHolder == Cardinality(holders) <= 1

\* A holder is alive and listens; a dead process holds nothing.
HoldersAlive == \A h \in holders : Live(h) /\ sock[h]

\* Lock only: every write of the lock line was by the holder.
LineWrittenByHolder == okLine

\* Lock only: every removal of a folder was by the holder.
FolderRemovedByHolder == okFolder

\* Folder cleanup never removes a folder of a live process.
NoLiveFolderRemoved == ~removedLive

\* Folder cleanup never removes a folder after a probe timeout.
NoRemovalAfterTimeout == ~removedTimeout

\* A grant belongs to the current holder, never to a dead holder.
GrantOwnedByHolder == holders = {} \/ ~grant \/ grantOwner \in holders

\* A queued prompt belongs to the current holder.
QueueOwnedByHolder == holders = {} \/ queue = 0 \/ queueOwner \in holders

\* An open permission question belongs to the current holder, never to a dead one.
QuestionOwnedByHolder == holders = {} \/ ~question \/ questionOwner \in holders

\* No model call starts without a client's ask for a turn.
CallsAreAsked == calls <= asks

\* A follower is connected only to a live process whose socket listens.
FollowerOnLiveSocket ==
    \/ fol # "connected"
    \/ (Live(folConn) /\ sock[folConn])

\* Liveness and action properties.

\* A dead holder's folder, named by the lock line, is removed by the next load
\* that takes the lock (not in today). A load that ends busy is the client's
\* to retry; the property needs a load that is waiting for the lock.
DeadFolderRemoved ==
    \A q \in Procs :
        ((line = q /\ folder[q] = "made" /\ st[q] = "dead" /\ ~reused[q])
            /\ \E p \in Procs : loading[p])
            ~> (folder[q] = "gone")

\* A loader either holds the lock or ends busy, or its process has ended.
LoadResolves ==
    \A p \in Procs :
        (loading[p] /\ Live(p)) ~> (p \in holders \/ busyOut[p] \/ ~Live(p))

\* A running turn whose owner died is repaired by the next load that takes
\* the lock.
TurnResolves ==
    ((turn = "running" /\ st[turnOwner] = "dead") /\ \E p \in Procs : loading[p])
        ~> (turn # "running")

\* A turn starts only when a client asked for it.
RunningOnlyAfterAsk ==
    [][(turn' = "running" /\ turn # "running") => (asks' = asks + 1)]_vars
\* Witnesses: each one must be violated, so the design reaches the behavior.
NoBusyLoad == \A p \in Procs : ~busyOut[p]
NoRepairedTurn == turn # "interrupted"
NoDeadFolderRemoved == \A q \in Procs : (folder[q] = "gone" => st[q] # "dead")
NoFollowerConnected == fol # "connected"
=============================================================================
