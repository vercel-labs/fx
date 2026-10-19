------------------------------- MODULE Resume -------------------------------
(***************************************************************************)
(* How fx closes and resumes a model request across process exits.         *)
(*                                                                         *)
(* Recovery.tla models the recovery module inside one fx process. This     *)
(* model takes the module's resume decision as given (recovery.zig         *)
(* resumeFrom) and checks what surrounds it: two fx processes that can     *)
(* open one session, the user, the files they share, and the ways a        *)
(* process ends.                                                           *)
(*                                                                         *)
(* The files are abstract cells, so the same rules can check the v2        *)
(* session store later: the session log's last seq, the turn snapshot      *)
(* (recovery.json), the request record (recovery.state) or a torn record,  *)
(* owner.live, recovery.asked, session.lock, and a copy of the session     *)
(* that /fork or a conversion makes. Request r is the one whose answer     *)
(* will be the log's seq r: it is open while the log's last seq is r - 1.  *)
(*                                                                         *)
(* A process ends in one of four ways:                                     *)
(* - Quit: /quit, Ctrl+C twice, or the end of an `fx ask` prompt. It is an *)
(*   explicit stop: quitting during a request cancels it first, as Esc     *)
(*   does, so the record and the snapshot are deleted and nothing resumes. *)
(* - Close: SIGHUP, SIGTERM, or terminal EOF. Only a close resumes. In the *)
(*   proposed design the TUI and ACP deliver `closing`, save the record    *)
(*   marked clean, and exit within about a second, and SIGKILL can cut the *)
(*   save short. `fx ask` cancels the request instead.                     *)
(* - Kill: SIGKILL, at any moment.                                         *)
(* - Crash: like Kill, and a record write in progress may survive, vanish, *)
(*   or tear.                                                              *)
(*                                                                         *)
(* Policy selects fx's behavior:                                           *)
(* - "today" is v1 as it ships. owner.live is written at every writable    *)
(*   open and deleted at a normal exit (session_log.zig                    *)
(*   trackOwnerLiveness, WritableSessionDir.deinit). A launch that finds   *)
(*   it, or finds recovery.asked, does not resume the checkpoint and says  *)
(*   fx quit unexpectedly (app_session_runtime.zig                         *)
(*   recoveryAutoContinueDecision). SIGHUP and SIGTERM only restore the    *)
(*   terminal and re-raise (app_lifecycle.zig), so they leave owner.live   *)
(*   behind. Terminal EOF runs the normal shutdown, which cancels the      *)
(*   request (app_entry_runtime.zig, main.zig shutdownForProcessExit).     *)
(*   recovery.asked lasts until the checkpoint is replaced or cleared. A   *)
(*   paused turn keeps its checkpoint (orchestrator.zig                    *)
(*   finishUncertainToolReview), so the next clean launch sends it again.  *)
(* - "proposed" is the closing design, and fx implements none of it yet:   *)
(*   recovery.state alone decides; it is fsynced before every send,        *)
(*   deleted at every end, and tied to the snapshot by the log seq; a      *)
(*   close saves it marked clean; a torn record beside an open turn counts *)
(*   as one abrupt death; a record older than a day, or stamped in the     *)
(*   future, asks before resending. A recovery.json left with no           *)
(*   recovery.state is never sent again on its own: the launch shows the   *)
(*   interrupted-turn notice, and the request goes out again only when the *)
(*   user sends a message such as "continue". owner.live is still written  *)
(*   but decides nothing, and recovery.asked is gone.                      *)
(*                                                                         *)
(* The record cannot tell a send that was saved but not yet sent from one  *)
(* on the wire, so a death in that window counts as an in-flight death, as *)
(* Recovery.tla's Visible does.                                            *)
(*                                                                         *)
(* Bug plants one defect in the proposed design, and DeathCount selects    *)
(* how the crash-loop rules count deaths. Each config names the one rule   *)
(* that must catch it.                                                     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Policy,      \* "today" or "proposed"
    AskProcs,    \* processes that run `fx ask`; the others are the TUI or ACP
    MaxReq,      \* requests the user may send in the session
    MaxFaults,   \* disruptions: closes, deaths, failures, stops, clock jumps
    DeathCount,  \* "seen", the rules' reading; "wire" and "every" are witnesses
    Bug          \* "none", or the name of one planted defect

Bugs == {"none", "no_seq_binding", "delete_before_commit", "torn_resets",
         "closing_joins_worker", "send_before_durable", "fork_copies_record",
         "no_lock", "owner_fallback"}

Procs == {1, 2}
Reqs  == 1..MaxReq

ASSUME /\ Policy \in {"today", "proposed"}
       /\ AskProcs \subseteq Procs
       /\ MaxReq \in Nat \ {0} /\ MaxFaults \in Nat
       /\ DeathCount \in {"seen", "wire", "every"}
       /\ Bug \in Bugs
       /\ (Bug # "none" \/ DeathCount # "seen") => Policy = "proposed"

CrashLoopAfter == 2   \* recovery.zig crash_loop_after
CloseBound     == 1   \* seconds a closing process may wait before it exits

Min(a, b) == IF a < b THEN a ELSE b

\* The wall clock in days. A record is stamped when it is written; the 24 h
\* rule compares the stamp to the clock.
Days == 0..1

\* recovery.state, reduced to what the launch reads. ph "none" is no file and
\* "torn" is a file that does not decode.
RecPhases == {"none", "torn", "sending", "waiting", "need_user"}
Records   == [ph: RecPhases, req: 0..MaxReq, clean: BOOLEAN,
              deaths: 0..CrashLoopAfter, at: Days]
NoRec == [ph |-> "none", req |-> 0, clean |-> FALSE, deaths |-> 0, at |-> 0]
Torn  == [NoRec EXCEPT !.ph = "torn"]

\* What a process is doing. "snap" and "rec" write the save for the next
\* send, "send" puts it on the wire, "flight" waits for its outcome.
PCs == {"off", "idle", "ask", "snap", "rec", "send", "flight", "wait",
        "commit", "delsnap", "delrec", "late", "end2", "closing",
        "closingwire"}
\* A process working on a request, from its first save to its last delete.
Working == PCs \ {"off", "idle", "ask"}
\* What a process shows about a leftover request: Today's "fx quit
\* unexpectedly" notice, the proposed crash-loop question, the proposed
\* question for an old record, or the proposed interrupted-turn notice for a
\* snapshot with no record. The notice asks nothing: it only says the turn
\* was not sent again.
Questions == {"none", "notice", "unclean", "crash", "old"}
Asks(q) == q \in {"unclean", "crash", "old"}
\* How the last process that had the session ended. "close" is a finished
\* clean close while working on a request and "idleclose" one with nothing
\* running or a question showing. A death is "inflight" when it tears the
\* record or leaves its own save of a send, saved but perhaps not yet sent,
\* and "wire" when that send was on the wire.
Exits == {"none", "quit", "close", "idleclose", "death", "inflight", "wire"}
Fates == {"none", "open", "ok", "cancel", "stop", "paused"}

Procs0 == [pc: PCs, cur: 0..MaxReq, md: 0..CrashLoopAfter, q: Questions,
           own: BOOLEAN, pend: Records, ticks: 0..CloseBound + 1]
OffProc == [pc |-> "off", cur |-> 0, md |-> 0, q |-> "none", own |-> FALSE,
            pend |-> NoRec, ticks |-> 0]

VARIABLES
    \* The session directory.
    log,        \* the log's last seq: requests that ended in the log
    snap,       \* recovery.json: 0, or the request it holds
    rec,        \* recovery.state (proposed only)
    owner,      \* owner.live exists
    asked,      \* recovery.asked exists (today only)
    lock,       \* session.lock holder, 0 for none
    copyRec,    \* the session copy carries a record
    wall,       \* the wall clock, in days
    \* Each process: pc, the request it works on or asks about (cur), the
    \* module's abrupt-death count in memory (md), the question it shows (q),
    \* whether its own save for its send is durable (own), the record write
    \* it has in progress (pend), and seconds spent waiting while closing.
    ps,
    \* The world and what the rules read.
    faults,     \* disruptions injected so far
    fate,       \* what became of each request
    lastExit,   \* how the last process that had the session ended
    seen,       \* in-flight deaths a launch can see since fx last saved
                \* the crash-loop question, or since the request started
    closed      \* a request closed cleanly that has not been sent again

diskVars  == <<log, snap, rec, owner, asked, lock, copyRec, wall>>
ghostVars == <<faults, fate, lastExit, seen, closed>>
vars      == <<diskVars, ps, ghostVars>>

TypeOK ==
    /\ log \in 0..MaxReq /\ snap \in 0..MaxReq /\ rec \in Records
    /\ owner \in BOOLEAN /\ asked \in BOOLEAN /\ lock \in {0} \cup Procs
    /\ copyRec \in BOOLEAN /\ wall \in Days
    /\ ps \in [Procs -> Procs0]
    /\ faults \in 0..MaxFaults /\ fate \in [Reqs -> Fates]
    /\ lastExit \in Exits /\ seen \in 0..CrashLoopAfter /\ closed \in 0..MaxReq

-----------------------------------------------------------------------------
(* Derived values.                                                         *)

Today    == Policy = "today"
Proposed == Policy = "proposed"
IsTui(p) == p \notin AskProcs
Alive(p) == ps[p].pc # "off"

CanFault == faults < MaxFaults

\* The request's turn is still open in the log. A write for a request whose
\* turn another writer ended fails (session_log.zig confirmWriter).
Fresh(p) == ps[p].cur > 0 /\ log + 1 = ps[p].cur

\* recovery.json holds the open turn. v1 drops a snapshot that names an
\* earlier seq (session_log.zig loadConversationRecoveryCheckpoint).
CurrentSnap == snap > 0 /\ snap = log + 1

LiveRec == rec.ph \in {"sending", "waiting", "need_user"}
\* The record names the open turn and sits beside its snapshot.
Bound   == LiveRec /\ rec.req = log + 1 /\ snap = rec.req
TornBeside == rec.ph = "torn" /\ CurrentSnap
\* The launch takes the record as the open turn's. Planted defect
\* no_seq_binding: it takes a record whose seq the log has passed too.
Reads == Bound \/ (LiveRec /\ Bug = "no_seq_binding")
\* Older than a day or stamped in the future: asks before resending.
Old == Proposed /\ Reads /\ rec.at # wall
\* The crash-loop question is saved and still unanswered.
PendingQ == Proposed /\ Reads /\ rec.ph = "need_user"

\* What the launch reads as an abrupt death with a send out. Today any
\* death beside a checkpoint is one, through owner.live.
VisibleDisk ==
    IF Proposed
       THEN \/ TornBeside
            \/ Reads /\ rec.ph = "sending" /\ ~rec.clean
       ELSE CurrentSnap

\* recovery.zig resumeFrom: the abrupt-death count after this launch. A torn
\* record counts as one death. Planted defect torn_resets: it starts fresh,
\* as recovery.zig's decode failure does today.
ModuleCount ==
    IF rec.ph = "torn" THEN IF Bug = "torn_resets" THEN 0 ELSE 1
    ELSE Min(rec.deaths + (IF rec.ph = "sending" /\ ~rec.clean THEN 1 ELSE 0),
             CrashLoopAfter)

\* The rules' count of in-flight deaths after this launch. "seen" counts what
\* the launch can see: a torn record shows exactly one death. "wire" counts
\* only deaths with the send on the wire. "every" adds a torn record's death
\* to the earlier ones it hid.
Counted == IF DeathCount = "wire" THEN {"wire"} ELSE {"inflight", "wire"}
LaunchCount ==
    IF Proposed /\ TornBeside
       THEN CASE DeathCount = "every" -> Min(seen + 1, CrashLoopAfter)
              [] DeathCount = "wire"  -> IF lastExit = "wire" THEN 1 ELSE 0
              [] OTHER                -> 1
       ELSE Min(seen + (IF lastExit \in Counted /\ VisibleDisk THEN 1 ELSE 0),
                CrashLoopAfter)

\* How a death of p classifies, given the record d it leaves: in flight when
\* it tears the record or leaves p's own save of a send.
DeathKind(p, d) ==
    IF \/ d = Torn /\ rec # Torn /\ ps[p].pend # NoRec
       \/ d = ps[p].pend /\ d.ph = "sending" /\ ~d.clean
       \/ d = rec /\ ps[p].own
       THEN IF ps[p].pc \in {"flight", "closingwire"} THEN "wire" ELSE "inflight"
       ELSE "death"

\* The open request r can be resumed from what is on disk.
Resumable(r) ==
    /\ snap = r /\ log + 1 = r
    /\ Today \/ rec.ph = "torn" \/ (LiveRec /\ rec.req = r)

SendingRec(p) == [ph |-> "sending", req |-> ps[p].cur, clean |-> FALSE,
                  deaths |-> ps[p].md, at |-> wall]

ClearClosed(r) == closed' = IF closed = r THEN 0 ELSE closed

-----------------------------------------------------------------------------
(* Launch.                                                                 *)

Init ==
    /\ log = 0 /\ snap = 0 /\ rec = NoRec /\ owner = FALSE /\ asked = FALSE
    /\ lock = 0 /\ copyRec = FALSE /\ wall = 0
    /\ ps = [p \in Procs |-> OffProc]
    /\ faults = 0 /\ fate = [r \in Reqs |-> "none"]
    /\ lastExit = "none" /\ seen = 0 /\ closed = 0

\* recovery.zig resumeFrom, for a launch or for Enter on the old-record
\* question: the second abrupt death asks once, saving the question;
\* otherwise save and send at once. n is the rules' count after it. The
\* count starts over when the question is saved (Sync): a question that
\* never reached the disk leaves both deaths in the record, and the next
\* launch asks again.
ModuleStart(p, r, n) ==
    LET c == ModuleCount IN
    /\ seen' = n
    /\ UNCHANGED rec
    /\ IF c >= CrashLoopAfter
          THEN ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "ask", !.cur = r,
                         !.md = c, !.q = "crash",
                         !.pend = [ph |-> "need_user", req |-> r, clean |-> FALSE,
                                   deaths |-> c, at |-> wall]]]
          ELSE ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "rec", !.cur = r,
                         !.md = c, !.q = "none"]]

\* app_session_runtime.zig hydrateResumedSession: a leftover marker means
\* the user decides; otherwise the checkpoint is saved again and sent.
TodayLaunch(p, n) ==
    /\ IF CurrentSnap /\ (asked \/ owner)
          THEN /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.q = "unclean"]]
               /\ asked' = TRUE
               /\ seen' = 0
          ELSE IF CurrentSnap
          THEN /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "snap", !.cur = snap]]
               /\ seen' = n
               /\ UNCHANGED asked
          ELSE /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle"]]
               /\ seen' = n
               /\ UNCHANGED asked
    /\ UNCHANGED rec

\* The record alone decides. A snapshot with no record is never sent again
\* on its own: the launch shows the interrupted-turn notice, and the turn goes
\* out again only as a new message (MoveOn). Planted defect owner_fallback,
\* the rejected alternative: with no record, a snapshot and no owner.live
\* resume on their own.
ProposedLaunch(p, n) ==
    /\ UNCHANGED asked
    /\ CASE TornBeside ->
              /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "rec", !.cur = snap,
                           !.md = ModuleCount]]
              /\ seen' = n
              /\ UNCHANGED rec
         [] Reads ->
              IF Old
                 THEN /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "ask",
                                   !.cur = rec.req, !.q = "old"]]
                      /\ seen' = n
                      /\ UNCHANGED rec
                 ELSE ModuleStart(p, rec.req, n)
         [] rec.ph # "none" ->
              \* A stale or torn record beside no open turn is deleted.
              /\ rec' = NoRec
              /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle",
                           !.q = IF CurrentSnap THEN "notice" ELSE "none"]]
              /\ seen' = n
         [] Bug = "owner_fallback" /\ CurrentSnap /\ ~owner ->
              /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "rec", !.cur = snap]]
              /\ seen' = 0
              /\ UNCHANGED rec
         [] OTHER ->
              /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle",
                           !.q = IF CurrentSnap THEN "notice" ELSE "none"]]
              /\ seen' = n
              /\ UNCHANGED rec

\* A process opens the session. It takes session.lock first, so a second
\* process gets SessionBusy and does nothing. Planted defect no_lock: it
\* opens the session anyway. `fx ask` resumes nothing on its own
\* (cli_ask.zig continue_recovery), but it is the first launch after the
\* death, so the rules count the death here.
Launch(p) ==
    /\ ~Alive(p)
    /\ lock = 0 \/ Bug = "no_lock"
    /\ lock' = IF lock = 0 THEN p ELSE lock
    /\ owner' = TRUE
    /\ lastExit' = "none"
    /\ IF IsTui(p)
          THEN IF Today THEN TodayLaunch(p, LaunchCount)
               ELSE ProposedLaunch(p, LaunchCount)
          ELSE /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle"]]
               /\ seen' = LaunchCount
               /\ UNCHANGED <<rec, asked>>
    /\ UNCHANGED <<log, snap, copyRec, wall, faults, fate, closed>>

-----------------------------------------------------------------------------
(* Requests.                                                               *)

\* The user sends a message. The snapshot is written before the first send;
\* a fresh checkpoint clears recovery.asked (session_log.zig
\* writeConversationRecoveryState). Today the snapshot is the save, written
\* with a send outstanding (orchestrator.zig persistRecoveryCheckpoint).
StartReq(p) ==
    /\ ps[p].pc = "idle" /\ ~CurrentSnap /\ log < MaxReq
    /\ fate[log + 1] = "none"
    /\ snap' = log + 1
    /\ asked' = FALSE
    /\ fate' = [fate EXCEPT ![log + 1] = "open"]
    /\ seen' = 0
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = IF Today THEN "send" ELSE "rec",
                 !.cur = log + 1, !.md = 0, !.q = "none", !.own = Today]]
    /\ UNCHANGED <<log, rec, owner, lock, copyRec, wall, faults, lastExit, closed>>

\* A new message, or "continue", while a checkpoint is left over: the old turn
\* becomes interrupted history first (session_log.zig, before a new prompt
\* replaces the recovery slot), which ends that request.
MoveOn(p) ==
    /\ ps[p].pc = "idle" /\ CurrentSnap
    /\ log' = snap
    /\ snap' = 0
    /\ rec' = NoRec
    /\ asked' = FALSE
    /\ fate' = IF fate[snap] = "open" THEN [fate EXCEPT ![snap] = "cancel"] ELSE fate
    /\ ps' = [ps EXCEPT ![p].q = "none"]
    /\ ClearClosed(snap)
    /\ UNCHANGED <<owner, lock, copyRec, wall, faults, lastExit, seen>>

\* Today: the checkpoint is saved again before each send, with a send
\* outstanding.
WriteSnap(p) ==
    /\ ps[p].pc = "snap" /\ Fresh(p)
    /\ asked' = FALSE
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "send", !.own = TRUE]]
    /\ UNCHANGED <<log, snap, rec, owner, lock, copyRec, wall, ghostVars>>

\* Proposed: the record for the send is written; Sync makes it durable.
WriteRec(p) ==
    /\ ps[p].pc = "rec" /\ Fresh(p) /\ ps[p].pend = NoRec
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "send", !.pend = SendingRec(p)]]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* Write, fsync, rename: the record write becomes durable. Once the
\* crash-loop question is saved, fx has asked.
Sync(p) ==
    /\ Alive(p) /\ ps[p].pend # NoRec
    /\ rec' = ps[p].pend
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pend = NoRec,
                 !.own = ps[p].pend.ph = "sending" /\ ~ps[p].pend.clean]]
    /\ seen' = IF ps[p].pend.ph = "need_user" THEN 0 ELSE seen
    /\ UNCHANGED <<log, snap, owner, asked, lock, copyRec, wall, faults, fate,
                   lastExit, closed>>

\* The send goes on the wire once its save is durable. Planted defect
\* send_before_durable: it goes out before the fsync.
SendOut(p) ==
    /\ ps[p].pc = "send"
    /\ ps[p].pend = NoRec \/ Bug = "send_before_durable"
    /\ ps' = [ps EXCEPT ![p].pc = "flight"]
    /\ ClearClosed(ps[p].cur)
    /\ UNCHANGED <<diskVars, faults, fate, lastExit, seen>>

\* The answer arrives; fx holds it in memory until the commit.
ArriveOk(p) ==
    /\ ps[p].pc = "flight"
    /\ ps' = [ps EXCEPT ![p].pc = "commit"]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* A network or gateway failure ends the send: the record is saved waiting
\* (proposed) or the checkpoint saved with no send outstanding (today,
\* orchestrator.zig), then fx waits.
Fail(p) ==
    /\ ps[p].pc = "flight" /\ Fresh(p) /\ CanFault
    /\ faults' = faults + 1
    /\ IF Proposed
          THEN ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "wait",
                         !.pend = [SendingRec(p) EXCEPT !.ph = "waiting"]]]
          ELSE ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "wait", !.own = FALSE]]
    /\ UNCHANGED <<diskVars, fate, lastExit, seen, closed>>

\* The wait ends: save and send again.
Retry(p) ==
    /\ ps[p].pc = "wait" /\ ps[p].pend = NoRec
    /\ ps' = [ps EXCEPT ![p].pc = IF Today THEN "snap" ELSE "rec"]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* Success: the answer is committed to the log, then the snapshot and the
\* record are deleted, each its own write (session_log.zig
\* finishConversationCommit). Planted defect delete_before_commit: both are
\* deleted before the commit.
Commit(p) ==
    /\ ps[p].pc = "commit" /\ Fresh(p) /\ Bug # "delete_before_commit"
    /\ log' = ps[p].cur
    /\ fate' = [fate EXCEPT ![ps[p].cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p].pc = "delsnap"]
    /\ ClearClosed(ps[p].cur)
    /\ UNCHANGED <<snap, rec, owner, asked, lock, copyRec, wall, faults,
                   lastExit, seen>>

DelSnap(p) ==
    /\ ps[p].pc = "delsnap"
    /\ snap' = 0
    /\ asked' = FALSE
    /\ ps' = [ps EXCEPT ![p] = IF Today
                 THEN [@ EXCEPT !.pc = "idle", !.cur = 0, !.own = FALSE]
                 ELSE [@ EXCEPT !.pc = "delrec"]]
    /\ UNCHANGED <<log, rec, owner, lock, copyRec, wall, ghostVars>>

DelRec(p) ==
    /\ ps[p].pc = "delrec"
    /\ rec' = NoRec
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0, !.own = FALSE]]
    /\ UNCHANGED <<log, snap, owner, asked, lock, copyRec, wall, ghostVars>>

EarlyDelete(p) ==
    /\ Bug = "delete_before_commit"
    /\ ps[p].pc = "commit" /\ Fresh(p)
    /\ snap' = 0
    /\ rec' = NoRec
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "late", !.own = FALSE]]
    /\ UNCHANGED <<log, owner, asked, lock, copyRec, wall, ghostVars>>

LateCommit(p) ==
    /\ ps[p].pc = "late" /\ Fresh(p)
    /\ log' = ps[p].cur
    /\ fate' = [fate EXCEPT ![ps[p].cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0, !.own = FALSE]]
    /\ ClearClosed(ps[p].cur)
    /\ UNCHANGED <<snap, rec, owner, asked, lock, copyRec, wall, faults,
                   lastExit, seen>>

\* Every end but success. Proposed: `finish` deletes the record, then the
\* checkpoint goes and the turn is logged as interrupted. Today: the
\* checkpoint is cleared, then the turn is logged (orchestrator.zig
\* clearRecoveryCheckpointOnUserCancel, stopRepeatedFailure).
EndAs(p, how) ==
    /\ fate' = [fate EXCEPT ![ps[p].cur] = how]
    /\ ClearClosed(ps[p].cur)
    /\ IF Proposed
          THEN /\ rec' = NoRec
               /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "end2", !.q = "none",
                            !.own = FALSE, !.pend = NoRec]]
               /\ UNCHANGED <<log, snap, asked>>
          ELSE /\ snap' = 0 /\ asked' = FALSE /\ log' = ps[p].cur
               /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0,
                            !.q = "none", !.own = FALSE]]
               /\ UNCHANGED rec

End2(p) ==
    /\ ps[p].pc = "end2"
    /\ snap' = 0
    /\ log' = IF Fresh(p) THEN ps[p].cur ELSE log
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0]]
    /\ UNCHANGED <<rec, owner, asked, lock, copyRec, wall, ghostVars>>

\* Esc twice while working or waiting, or once on a question: user_cancel.
\* /quit and Ctrl+C twice during a request do the same before Quit: an
\* explicit stop deletes the record and the snapshot, and nothing resumes.
Esc(p) ==
    /\ IsTui(p) /\ ps[p].pc \in {"flight", "wait", "ask"}
    /\ ps[p].pend = NoRec /\ Fresh(p)
    /\ EndAs(p, "cancel")
    /\ UNCHANGED <<owner, lock, copyRec, wall, faults, lastExit, seen>>

\* fx ends the request itself: an unclear failure that keeps repeating, a
\* terminal failure kind, or quota.
Stop(p) ==
    /\ ps[p].pc = "flight" /\ Fresh(p) /\ CanFault
    /\ faults' = faults + 1
    /\ EndAs(p, "stop")
    /\ UNCHANGED <<owner, lock, copyRec, wall, lastExit, seen>>

\* A resend that had to reconcile an uncertain tool returned another tool
\* call: the turn pauses for the user and its checkpoint stays (today). The
\* proposed `finish` deletes the record; the snapshot stays to inspect.
Pause(p) ==
    /\ ps[p].pc = "flight" /\ Fresh(p) /\ CanFault
    /\ faults' = faults + 1
    /\ fate' = [fate EXCEPT ![ps[p].cur] = "paused"]
    /\ rec' = NoRec
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0, !.own = FALSE,
                 !.pend = NoRec]]
    /\ ClearClosed(ps[p].cur)
    /\ UNCHANGED <<log, snap, owner, asked, lock, copyRec, wall, lastExit, seen>>

\* Enter on the old-record question: start(.{ .resume_from = record }).
EnterOld(p) ==
    /\ IsTui(p) /\ ps[p].pc = "ask" /\ ps[p].q = "old"
    /\ LiveRec /\ rec.req = ps[p].cur
    /\ ModuleStart(p, ps[p].cur, seen)
    /\ UNCHANGED <<log, snap, owner, asked, lock, copyRec, wall, faults, fate,
                   lastExit, closed>>

\* Enter on the crash-loop question: user_continue resets the death count.
EnterCrash(p) ==
    /\ IsTui(p) /\ ps[p].pc = "ask" /\ ps[p].q = "crash" /\ ps[p].pend = NoRec
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "rec", !.md = 0, !.q = "none"]]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* A writer whose turn another writer ended stops (SessionWriterChanged).
\* Only the planted no_lock defect gets here.
Fence(p) ==
    /\ ps[p].pc \in {"snap", "rec", "send", "flight", "wait", "commit", "late"}
    /\ ~Fresh(p)
    /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "idle", !.cur = 0, !.own = FALSE]]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* /fork or a conversion copies the session directory. Only the log prefix
\* crosses, with an open turn marked interrupted (session_log.zig
\* copy_conversation_recovery_prefix). Planted defect fork_copies_record:
\* the record crosses too.
CopySession(p) ==
    /\ Alive(p) /\ rec.ph # "none" /\ ~copyRec
    /\ copyRec' = (Bug = "fork_copies_record")
    /\ UNCHANGED <<log, snap, rec, owner, asked, lock, wall, ps, ghostVars>>

-----------------------------------------------------------------------------
(* Exits.                                                                  *)

Exit(p, how) ==
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = IF lock = p THEN 0 ELSE lock
    /\ lastExit' = how

\* /quit, Ctrl+C twice, or the end of an `fx ask` prompt, with no request
\* running: deinit deletes owner.live. During a request these cancel it
\* first (Esc). Quitting at the old-record question leaves the record, since
\* the module never started.
Quit(p) ==
    /\ \/ ps[p].pc = "idle"
       \/ ps[p].pc = "ask" /\ ps[p].q = "old"
    /\ owner' = FALSE
    /\ Exit(p, "quit")
    /\ UNCHANGED <<log, snap, rec, asked, copyRec, wall, faults, fate, seen, closed>>

\* SIGKILL, a crash, or power loss. A record write in progress may survive,
\* vanish, or tear. The lock goes with the process.
Die(p) ==
    /\ Alive(p) /\ CanFault
    /\ faults' = faults + 1
    /\ \E d \in IF ps[p].pend = NoRec THEN {rec} ELSE {rec, ps[p].pend, Torn}:
           /\ rec' = d
           /\ Exit(p, DeathKind(p, d))
    /\ UNCHANGED <<log, snap, owner, asked, copyRec, wall, fate, seen, closed>>

\* Today, SIGHUP or SIGTERM in the TUI or ACP: the handler restores the
\* terminal and re-raises (app_lifecycle.zig); ACP installs none. Nothing is
\* saved and owner.live stays.
TodayClose(p) ==
    /\ Today /\ IsTui(p) /\ Alive(p) /\ CanFault
    /\ faults' = faults + 1
    /\ LET working == ps[p].pc \in Working /\ fate[ps[p].cur] = "open" IN
       /\ closed' = IF working THEN ps[p].cur ELSE closed
       /\ Exit(p, IF working THEN "close" ELSE "idleclose")
    /\ UNCHANGED <<log, snap, rec, owner, asked, copyRec, wall, fate, seen>>

\* Today, terminal EOF in the TUI, or EOF on ACP's stdin: the normal
\* shutdown runs (app_entry_runtime.zig TerminalInputClosed, acp/server.zig
\* handleCancel), which cancels the request and clears its checkpoint, and
\* deinit deletes owner.live. The close loses the request.
TodayEof(p) ==
    /\ Today /\ IsTui(p) /\ CanFault /\ ps[p].pc \in {"idle", "flight", "wait"}
    /\ faults' = faults + 1
    /\ LET working == ps[p].pc # "idle" /\ Fresh(p) IN
       /\ IF working
             THEN /\ fate' = [fate EXCEPT ![ps[p].cur] = "cancel"]
                  /\ snap' = 0 /\ asked' = FALSE /\ log' = ps[p].cur
             ELSE UNCHANGED <<fate, snap, asked, log>>
       /\ closed' = IF working THEN ps[p].cur ELSE closed
       /\ Exit(p, IF working THEN "close" ELSE "idleclose")
    /\ owner' = FALSE
    /\ UNCHANGED <<rec, copyRec, wall, seen>>

\* Proposed, SIGHUP, SIGTERM, or terminal EOF in the TUI or ACP: fx delivers
\* `closing` between plans and saves the module's record marked clean. With
\* nothing running there is nothing to save.
ProposedClose(p) ==
    /\ Proposed /\ IsTui(p) /\ CanFault /\ ps[p].pend = NoRec
    /\ ps[p].pc \in {"idle", "ask", "flight", "wait"}
    /\ faults' = faults + 1
    /\ IF ps[p].pc = "idle" \/ ps[p].q = "old"
          THEN /\ Exit(p, "idleclose")
               /\ UNCHANGED closed
          ELSE /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT
                     !.pc = IF ps[p].pc = "flight" THEN "closingwire" ELSE "closing",
                     !.pend = [ph |-> CASE ps[p].pc = "flight" -> "sending"
                                        [] ps[p].pc = "wait"   -> "waiting"
                                        [] OTHER               -> "need_user",
                               req |-> ps[p].cur, clean |-> TRUE,
                               deaths |-> ps[p].md, at |-> wall]]]
               /\ UNCHANGED <<lock, lastExit, closed>>
    /\ UNCHANGED <<log, snap, rec, owner, asked, copyRec, wall, fate, seen>>

\* Once the clean record is durable, fx exits at once: it never waits for
\* the worker, whose send may still be on the wire. Planted defect
\* closing_joins_worker: it waits for that send to settle, as the shutdown
\* join does today (main.zig shutdownForProcessExit).
ExitClean(p) ==
    /\ ps[p].pc \in {"closing", "closingwire"} /\ ps[p].pend = NoRec
    /\ ~(Bug = "closing_joins_worker" /\ ps[p].pc = "closingwire")
    /\ LET working == ps[p].q # "crash" /\ fate[ps[p].cur] = "open" IN
       /\ closed' = IF working THEN ps[p].cur ELSE closed
       /\ Exit(p, IF working THEN "close" ELSE "idleclose")
    /\ UNCHANGED <<log, snap, rec, owner, asked, copyRec, wall, faults, fate, seen>>

\* The send's outcome arrives while closing. fx delivers no more events, so
\* it is discarded.
Settle(p) ==
    /\ ps[p].pc = "closingwire"
    /\ ps' = [ps EXCEPT ![p].pc = "closing"]
    /\ UNCHANGED <<diskVars, ghostVars>>

\* `fx ask`: SIGINT or SIGTERM cancels the request and exits 143
\* (cli_ask.zig); deinit deletes owner.live. Taken as one step.
AskClose(p) ==
    /\ ~IsTui(p) /\ CanFault /\ ps[p].pend = NoRec
    /\ ps[p].pc \in {"idle", "flight", "wait"}
    /\ faults' = faults + 1
    /\ IF ps[p].pc # "idle" /\ Fresh(p)
          THEN /\ fate' = [fate EXCEPT ![ps[p].cur] = "cancel"]
               /\ rec' = NoRec /\ snap' = 0 /\ asked' = FALSE /\ log' = ps[p].cur
          ELSE UNCHANGED <<fate, rec, snap, asked, log>>
    /\ owner' = FALSE
    /\ Exit(p, "quit")
    /\ UNCHANGED <<copyRec, wall, seen, closed>>

\* A second passes while a closing process waits on something other than
\* its own work. Every step fx takes for itself is immediate.
Tick ==
    \E p \in Procs:
        /\ Bug = "closing_joins_worker"
        /\ ps[p].pc = "closingwire" /\ ps[p].pend = NoRec
        /\ ps[p].ticks <= CloseBound
        /\ ps' = [ps EXCEPT ![p].ticks = @ + 1]
        /\ UNCHANGED <<diskVars, ghostVars>>

\* A day passes, or the wall clock is set back.
DayPasses ==
    /\ wall = 0 /\ wall' = 1
    /\ UNCHANGED <<log, snap, rec, owner, asked, lock, copyRec, ps, ghostVars>>

ClockBack ==
    /\ wall = 1 /\ faults < MaxFaults
    /\ wall' = 0 /\ faults' = faults + 1
    /\ UNCHANGED <<log, snap, rec, owner, asked, lock, copyRec, ps, fate,
                   lastExit, seen, closed>>

-----------------------------------------------------------------------------

Next ==
    \/ \E p \in Procs:
        \/ Launch(p) \/ StartReq(p) \/ MoveOn(p) \/ Quit(p)
        \/ WriteSnap(p) \/ WriteRec(p) \/ Sync(p) \/ SendOut(p)
        \/ ArriveOk(p) \/ Fail(p) \/ Retry(p) \/ Stop(p) \/ Pause(p)
        \/ Commit(p) \/ DelSnap(p) \/ DelRec(p) \/ EarlyDelete(p) \/ LateCommit(p)
        \/ Esc(p) \/ End2(p) \/ EnterOld(p) \/ EnterCrash(p)
        \/ Die(p) \/ TodayClose(p) \/ TodayEof(p) \/ ProposedClose(p) \/ AskClose(p)
        \/ ExitClean(p) \/ Settle(p) \/ Fence(p) \/ CopySession(p)
    \/ Tick \/ DayPasses \/ ClockBack
    \/ UNCHANGED vars

\* A TUI is opened again, fx carries out what it started, a send gets an
\* answer, `fx ask` ends, and a user who keeps seeing a question eventually
\* answers it with Enter. Faults, exits, Esc, and new messages are never
\* forced.
Relaunch == \E p \in Procs \ AskProcs: Launch(p)
Fairness ==
    /\ SF_vars(Relaunch)
    /\ \A p \in Procs:
        /\ WF_vars(ArriveOk(p))
        /\ WF_vars(WriteSnap(p)) /\ WF_vars(WriteRec(p)) /\ WF_vars(Sync(p))
        /\ WF_vars(SendOut(p)) /\ WF_vars(Retry(p)) /\ WF_vars(Commit(p))
        /\ WF_vars(DelSnap(p)) /\ WF_vars(DelRec(p)) /\ WF_vars(End2(p))
        /\ WF_vars(ExitClean(p)) /\ WF_vars(Fence(p))
        /\ SF_vars(EnterOld(p)) /\ SF_vars(EnterCrash(p))
        /\ (p \in AskProcs => WF_vars(Quit(p)))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* The rules.                                                              *)

Launches(p) == ~Alive(p) /\ Alive(p)'
\* A process starts sending a request: a launch that resumes it, Enter on a
\* question, or a new message.
StartsWork(p) ==
    /\ ps[p].pc \in {"off", "idle", "ask"}
    /\ ps'[p].pc \in {"snap", "rec", "send"}

\* A close (SIGHUP, SIGTERM, or terminal EOF) resumes without a question.
\* Today fails it: SIGHUP and SIGTERM leave owner.live, and the next launch
\* says fx quit unexpectedly.
NoQuestionAfterCleanClose ==
    [][\A p \in Procs:
         (Launches(p) /\ lastExit = "close" /\ ~Old) => ~Asks(ps'[p].q)]_vars

\* Only closes resume, so a close keeps the request: once it finishes, the
\* request is still open and can be resumed from disk. Today fails it:
\* terminal EOF runs the normal shutdown, which cancels the request.
CloseKeepsRequest ==
    [][\A p \in Procs, r \in Reqs:
         (Alive(p) /\ ~Alive(p)' /\ lastExit' = "close" /\ ps[p].cur = r)
             => (fate'[r] = "open" /\ Resumable(r)')]_vars

\* A question never outlives its cause: after a normal quit, a launch asks
\* only what the record it reads still shows, its age or a crash loop in
\* its count, and never because an earlier launch asked. Today fails it:
\* recovery.asked survives a clean quit, and the next launch says fx quit
\* unexpectedly again.
NotSticky ==
    [][\A p \in Procs:
         (Launches(p) /\ lastExit = "quit" /\ Asks(ps'[p].q)) =>
             \/ ps'[p].q = "old" /\ Old
             \/ ps'[p].q = "crash" /\ ModuleCount >= CrashLoopAfter]_vars

\* Resume after one abrupt death without asking: a launch asks about a
\* crash loop only at the second in-flight death it can see since fx last
\* asked. It can see a death that leaves a send saved and unfinished,
\* whether or not the send was on the wire, and a torn record, as one death.
\* Today fails it: one death leaves owner.live, and the launch asks.
NoQuestionAfterOneDeath ==
    [][\A p \in Procs:
         /\ (/\ Launches(p) /\ lastExit \in {"death", "inflight", "wire"}
             /\ ~Old /\ ~PendingQ /\ LaunchCount < CrashLoopAfter)
                => ~Asks(ps'[p].q)
         /\ (EnterOld(p) /\ ps'[p].q = "crash")
                => (seen >= CrashLoopAfter \/ PendingQ)]_vars

\* The second in-flight death a launch can see, since fx last asked about a
\* crash loop, asks (recovery.zig resumeFrom). fx has asked once the
\* question is saved. A torn record shows one death, so a torn record that
\* held the question, or the count, loses it.
CrashLoopAsks ==
    [][\A p \in Procs:
         /\ (/\ Launches(p) /\ IsTui(p) /\ lastExit \in {"inflight", "wire"}
             /\ VisibleDisk /\ ~Old /\ LaunchCount >= CrashLoopAfter)
                => ps'[p].q \in {"crash", "unclean"}
         /\ (EnterOld(p) /\ seen >= CrashLoopAfter) => ps'[p].q = "crash"]_vars

\* An answer the log holds is never sent again: a record left by a crash
\* after the commit names a seq the log has passed, so the launch deletes it.
NoResumeAfterCommit ==
    [][\A p \in Procs:
         StartsWork(p) => fate'[ps'[p].cur] # "ok"]_vars

\* A request that was cancelled, stopped by fx, or paused is never sent
\* again: every end deletes the record, and /quit and Ctrl+C twice cancel.
\* Today fails it: a paused turn keeps its checkpoint, and the next clean
\* launch sends it.
NoResumeAfterEnd ==
    [][\A p \in Procs:
         StartsWork(p) => fate'[ps'[p].cur] \notin {"cancel", "stop", "paused"}]_vars

\* An open request that can be resumed from disk stays resumable until it
\* ends: nothing deletes it before its answer is committed.
NoLostRequest ==
    [][\A r \in Reqs:
         (fate[r] = "open" /\ fate'[r] = "open" /\ Resumable(r)) => Resumable(r)']_vars

\* Only one process works on the session's request: session.lock admits one
\* writer, and a second process gets SessionBusy.
OneResumer ==
    \A p, o \in Procs: p # o => ~(ps[p].pc \in Working /\ ps[o].pc \in Working)

\* A record belongs to the session that wrote it: a copy never carries one.
RecordBound == ~copyRec

\* Every send goes out after its own save is durable: the record, or today
\* the checkpoint.
SaveDurableBeforeSend == \A p \in Procs: ps[p].pc = "flight" => ps[p].own

\* A closing process exits within about a second.
BoundedClosing == \A p \in Procs: ps[p].ticks <= CloseBound

\* A record older than a day, or stamped in the future, asks before
\* resending. Today reads no age (app_session_runtime.zig
\* recoveryAutoContinueDecision), so this rule checks the proposed design
\* only.
OldAsks ==
    [][\A p \in Procs:
         (Launches(p) /\ IsTui(p) /\ Old) => Asks(ps'[p].q)]_vars

\* After a close (SIGHUP, SIGTERM, or terminal EOF) the request is
\* eventually sent again, or the user or fx ends it later. A close that ends
\* the request itself leaves it waiting forever.
ResumesAfterClose == closed # 0 ~> closed = 0

\* The rules' death count matches the record's: between processes, what the
\* rules count for the next launch is what the module will count from the
\* record. A check of the model, listed only where every rule must hold.
CountsAgree ==
    (/\ \A p \in Procs: ~Alive(p)
     /\ Proposed /\ DeathCount = "seen"
     /\ (TornBeside \/ (Bound /\ rec.ph # "need_user")))
        => LaunchCount = ModuleCount

=============================================================================
