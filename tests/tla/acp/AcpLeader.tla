--------------------------- MODULE AcpLeader ---------------------------
(***************************************************************************)
(* The lock of a session names the fx acp process that holds it, and that  *)
(* process's leader socket, so another fx acp can find the holder.         *)
(*                                                                         *)
(* - A process starts its leader socket before it opens any session.       *)
(* - A process that holds a session's lock records itself in the lock file *)
(*   once its socket listens. It clears the record before it unlocks; a    *)
(*   normal exit closes every session first.                               *)
(* - A process that is killed keeps its record in the lock file, and its   *)
(*   socket stops answering. Nothing clears that record until the next     *)
(*   holder writes or empties it.                                          *)
(* - A process whose socket cannot start takes a lock with no record, and  *)
(*   empties the record a dead holder left.                                *)
(* - A reader connects to the socket the lock file names. A socket that    *)
(*   does not answer is stale only when its process is gone. A socket      *)
(*   that answers reaches its process, which says whether it leads the     *)
(*   session.                                                              *)
(*                                                                         *)
(* Records = FALSE gives fx acp before the record: a holder never names    *)
(* itself in the lock file.                                                *)
(***************************************************************************)
CONSTANTS
    Procs,      \* the fx acp processes that may run; each runs once
    Records     \* TRUE: fx records its socket in the lock file; FALSE: not

None == "no process"

VARIABLES
    started,    \* the process has started
    alive,      \* the process has not exited or been killed
    listening,  \* the process's leader socket listens
    failed,     \* the process's leader socket could not start
    locked,     \* ghost: the process has taken a session lock, once
    holder,     \* the process that holds the session's lock, or None
    record,     \* the process the lock file names, or None
    leads,      \* the process lists the session
    fstep,      \* the reader's step
    ftarget,    \* the process the lock file named when the reader read it
    fconn,      \* the process the reader connected to
    foundOk,    \* ghost: a found answer came from the lock's holder
    staleOk     \* ghost: a stale socket belonged to a dead process

procVars == <<started, alive, listening, failed, locked, holder, record,
              leads>>
followVars == <<fstep, ftarget, fconn, foundOk, staleOk>>
vars == <<procVars, followVars>>

Init ==
    /\ started = [p \in Procs |-> FALSE]
    /\ alive = [p \in Procs |-> FALSE]
    /\ listening = [p \in Procs |-> FALSE]
    /\ failed = [p \in Procs |-> FALSE]
    /\ locked = [p \in Procs |-> FALSE]
    /\ holder = None
    /\ record = None
    /\ leads = [p \in Procs |-> FALSE]
    /\ fstep = "idle"
    /\ ftarget = None
    /\ fconn = None
    /\ foundOk = FALSE
    /\ staleOk = FALSE

\* A process starts.
Start(p) ==
    /\ ~started[p]
    /\ started' = [started EXCEPT ![p] = TRUE]
    /\ alive' = [alive EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<listening, failed, locked, holder, record, leads>>
    /\ UNCHANGED followVars

\* A started process starts its leader socket, unless it has failed to.
Listen(p) ==
    /\ alive[p] /\ ~listening[p] /\ ~failed[p]
    /\ listening' = [listening EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<started, alive, failed, locked, holder, record, leads>>
    /\ UNCHANGED followVars

\* The socket cannot start, or stops because fx cannot set its record. The
\* process then runs without a socket, and never listens again. In fx the
\* socket stops without a record only at start, before the first lock:
\* startLeader runs before the reader loop.
Fail(p) ==
    /\ alive[p] /\ ~failed[p] /\ ~locked[p]
    /\ failed' = [failed EXCEPT ![p] = TRUE]
    /\ listening' = [listening EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<started, alive, locked, holder, record, leads>>
    /\ UNCHANGED followVars

\* A process takes a free session lock, once its socket listens or once it
\* has failed to start one. Without a socket the lock is emptied, so a dead
\* holder's record does not outlive the new holder.
Lock(p) ==
    /\ alive[p] /\ holder = None
    /\ (listening[p] \/ failed[p])
    /\ holder' = p
    /\ record' = IF failed[p] THEN None ELSE record
    /\ locked' = [locked EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<started, alive, listening, failed, leads>>
    /\ UNCHANGED followVars

\* The holder records its listening socket in the lock file and lists the
\* session.
Record(p) ==
    /\ Records
    /\ holder = p /\ listening[p] /\ record # p
    /\ record' = p
    /\ leads' = [leads EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<started, alive, listening, failed, locked, holder>>
    /\ UNCHANGED followVars

\* The holder clears its record and stops listing the session.
Clear(p) ==
    /\ holder = p /\ record = p
    /\ record' = None
    /\ leads' = [leads EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<started, alive, listening, failed, locked, holder>>
    /\ UNCHANGED followVars

\* The holder unlocks once its record is clear and it lists nothing.
Unlock(p) ==
    /\ holder = p /\ record # p /\ ~leads[p]
    /\ holder' = None
    /\ UNCHANGED <<started, alive, listening, failed, locked, record, leads>>
    /\ UNCHANGED followVars

\* A normal exit: the process stops listening and ends, after it closed its
\* sessions.
Exit(p) ==
    /\ alive[p] /\ holder # p
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ listening' = [listening EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<started, failed, locked, holder, record, leads>>
    /\ UNCHANGED followVars

\* The process is killed: it ends at once and its lock is released. Nothing
\* clears its record.
Crash(p) ==
    /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ listening' = [listening EXCEPT ![p] = FALSE]
    /\ leads' = [leads EXCEPT ![p] = FALSE]
    /\ holder' = IF holder = p THEN None ELSE holder
    /\ UNCHANGED <<started, failed, locked, record>>
    /\ UNCHANGED followVars

\* The reader reads the lock file: it names a process, or nothing.
Read ==
    /\ fstep = "idle"
    /\ ftarget' = record
    /\ fstep' = IF record = None THEN "none" ELSE "read"
    /\ UNCHANGED <<fconn, foundOk, staleOk>>
    /\ UNCHANGED procVars

\* The reader connects to the socket the lock file named. A socket that
\* answers reaches its process; otherwise the socket is stale.
Connect ==
    /\ fstep = "read"
    /\ IF listening[ftarget]
       THEN /\ fstep' = "connected"
            /\ fconn' = ftarget
            /\ UNCHANGED <<staleOk>>
       ELSE /\ fstep' = "stale"
            /\ staleOk' = ~alive[ftarget]
            /\ UNCHANGED <<fconn>>
    /\ UNCHANGED <<ftarget, foundOk>>
    /\ UNCHANGED procVars

\* The reader asks the process it reached whether it leads the session. The
\* answer is found when the process leads it, and notleader otherwise.
Ask ==
    /\ fstep = "connected"
    /\ IF leads[fconn]
       THEN /\ fstep' = "found"
            /\ foundOk' = (holder = fconn)
       ELSE /\ fstep' = "notleader"
            /\ UNCHANGED <<foundOk>>
    /\ UNCHANGED <<ftarget, fconn, staleOk>>
    /\ UNCHANGED procVars

\* The reader starts again after any end state.
Again ==
    /\ fstep \in {"none", "stale", "found", "notleader"}
    /\ fstep' = "idle"
    /\ UNCHANGED <<ftarget, fconn, foundOk, staleOk>>
    /\ UNCHANGED procVars

Next ==
    \/ \E p \in Procs :
        \/ Start(p) \/ Listen(p) \/ Fail(p) \/ Lock(p) \/ Record(p)
        \/ Clear(p) \/ Unlock(p) \/ Exit(p) \/ Crash(p)
    \/ Read \/ Connect \/ Ask \/ Again

\* Weak fairness: a process that can record its listening socket does so.
Spec == Init /\ [][Next]_vars /\ \A p \in Procs : WF_vars(Record(p))

-----------------------------------------------------------------------------
\* Forbids a variable outside its type.
TypeOK ==
    /\ started \in [Procs -> BOOLEAN] /\ alive \in [Procs -> BOOLEAN]
    /\ listening \in [Procs -> BOOLEAN] /\ failed \in [Procs -> BOOLEAN]
    /\ locked \in [Procs -> BOOLEAN]
    /\ leads \in [Procs -> BOOLEAN]
    /\ holder \in Procs \cup {None} /\ record \in Procs \cup {None}
    /\ fstep \in {"idle", "read", "none", "connected", "stale", "found",
                  "notleader"}
    /\ ftarget \in Procs \cup {None} /\ fconn \in Procs \cup {None}
    /\ foundOk \in BOOLEAN /\ staleOk \in BOOLEAN

\* Forbids listing a session whose lock the process does not hold.
LeadsImpliesHolds == \A p \in Procs : leads[p] => holder = p

\* Forbids a lock file that names a live process which does not hold the
\* lock or does not listen.
RecordNamesHolder ==
    \A p \in Procs : (record = p /\ alive[p]) => (holder = p /\ listening[p])

\* Forbids a reader that connects to a process other than the one the lock
\* file named.
ReachedTarget ==
    fstep \in {"connected", "found", "notleader"} => fconn = ftarget

\* Forbids a found answer from a process that does not hold the session's
\* lock.
FoundIsHolder == fstep = "found" => foundOk

\* Forbids calling a socket stale while its process is alive.
StaleOnlyIfDead == fstep = "stale" => staleOk

\* Forbids a listening holder that the lock file never names, unless the
\* holder lets go or dies.
RecordFollowsLock ==
    \A p \in Procs :
        (holder = p /\ alive[p] /\ listening[p])
            ~> (record = p \/ holder # p \/ ~alive[p])
=============================================================================
