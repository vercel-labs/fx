------------------------------- MODULE Resume -------------------------------
(***************************************************************************)
(* How the interactive app resumes a model request after fx dies or is     *)
(* closed in the middle of a turn.                                         *)
(*                                                                         *)
(* Recovery.tla models the recovery module inside one fx process. This     *)
(* model takes the module's resume decision as given (recovery.zig         *)
(* resumeFrom) and checks what surrounds it: two fx processes that can     *)
(* open one session, the user, the session log they share, and the ways a  *)
(* process ends.                                                           *)
(*                                                                         *)
(* The log is reduced to its newest turn: the request it serves, how it    *)
(* ended, the newest `recovery` piece it holds (the module's record), what *)
(* its other pieces show, and the day that record was saved. A turn that   *)
(* is still open when a launch opens the session is ended `crash` by the   *)
(* session manager. The writer lock lets one process write the session.    *)
(*                                                                         *)
(* A process ends in one of four ways:                                     *)
(* - Quit: /quit or Ctrl+C twice. It cancels the request first, as Esc     *)
(*   does, so nothing resumes.                                             *)
(* - Close: SIGHUP or SIGTERM, from a closed window, a logout, or a        *)
(*   reboot. A closed window can reach fx as its terminal hanging up       *)
(*   before SIGHUP, and closes fx the same way. fx gives the module        *)
(*   `closing`, saves the record it returns, which is marked clean, and    *)
(*   exits.                                                                *)
(* - Kill: SIGKILL or a crash, at any moment.                              *)
(* - Relaunch: Ctrl+G installs an upgrade and restarts fx (Upgrade). A     *)
(*   running turn stops at its next save before a model request once the   *)
(*   turn is in the log (src/core/quiesce/): fx saves the record marked    *)
(*   clean, marks the turn as yielded, and holds it there (Hold). fx       *)
(*   re-execs once it holds (Relaunch), and the next launch continues that *)
(*   turn with no note to the model. Until then a second Ctrl+G cancels    *)
(*   the restart (CancelRestart): the held turn sends, after saving its    *)
(*   send's record again. While the restart waits, a new message is held.  *)
(*   This is fx now, with the "proposed" policy: under "today", fx before  *)
(*   its recovery records, Ctrl+G refused while a turn ran. If the save    *)
(*   before the hold does not land, the turn goes on, and the next save    *)
(*   asks again (YieldSaveFails).                                          *)
(*                                                                         *)
(* Policy selects fx's behavior:                                           *)
(* - "today" saves no record, and a close dies as a kill does. A launch    *)
(*   shows the interrupted turn, and the request goes out again only when  *)
(*   the user sends a message such as "continue".                          *)
(* - "proposed" saves the module's record before every send and clears it  *)
(*   when the request's response arrives. A launch that finds a turn ended *)
(*   by a crash, with a request or tool work unfinished, continues the     *)
(*   stopped turn as the same turn, with fx's resume notice. The module    *)
(*   sends at once, or asks: after the request crashed fx twice with a     *)
(*   send in flight, when its record is more than a day old, or when it    *)
(*   was waiting for the user. A turn reaches the log with its first send, *)
(*   in one write with that send's record; a turn that asks first is       *)
(*   written when the question shows.                                      *)
(*                                                                         *)
(* A save and the send it goes with are one step: the record cannot tell a *)
(* send that was saved but not yet sent from one on the wire, so a death   *)
(* in that window counts as an in-flight death, as Recovery.tla's Visible  *)
(* does.                                                                   *)
(*                                                                         *)
(* Bug plants one defect in the proposed design. Each config names the one *)
(* rule that must catch it.                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Policy,     \* "today" or "proposed"
    MaxReq,     \* requests the user may send in the session
    MaxFaults,  \* disruptions: kills, closes, failures, a day passing
    Bug         \* "none", or the name of one planted defect

Bugs == {"none", "no_closing", "no_clear", "send_before_save",
         "reset_on_resume", "resume_answered", "resume_cancelled",
         "ignore_age", "no_lock", "yield_unclean", "yield_first",
         "yield_unsaved", "note_turn", "cancel_strands",
         "cancel_keeps_relaunch", "cancel_unsaved"}

Procs == {1, 2}
Reqs  == 1..MaxReq

ASSUME /\ Policy \in {"today", "proposed"}
       /\ MaxReq \in Nat \ {0} /\ MaxFaults \in Nat
       /\ Bug \in Bugs
       /\ Bug # "none" => Policy = "proposed"

CrashLoopAfter == 2   \* recovery.zig crash_loop_after

Min(a, b) == IF a < b THEN a ELSE b

\* The wall clock in days. A record is stamped when it is saved; the
\* 24-hour rule compares the stamp to the clock.
Days == 0..1

\* The newest `recovery` piece of the turn, reduced to what a launch reads.
\* ph "none" is no piece, or one a finished request wrote to clear it.
\* need names the question a `need` record waits on.
RecPhases == {"none", "sending", "waiting", "need"}
Needs     == {"none", "crash", "old", "other"}
Records   == [ph: RecPhases, clean: BOOLEAN, deaths: 0..CrashLoopAfter,
              need: Needs]
NoRec == [ph |-> "none", clean |-> FALSE, deaths |-> 0, need |-> "none"]

\* How the newest turn ended. "open" has no end yet.
TurnEnds == {"open", "done", "cancel", "crash"}
\* What the turn's other pieces show after its newest finished request:
\* nothing yet, tool calls or results the model has not seen, or the final
\* answer.
Works == {"none", "tools", "final"}
Turns == [req: 0..MaxReq, st: TurnEnds, rec: Records, work: Works, at: Days]
NoTurn == [req |-> 0, st |-> "done", rec |-> NoRec, work |-> "none", at |-> 0]

\* What a process is doing. "save" has the module started and about to save
\* and send; "flight" has that send on the wire; "late" (send_before_save
\* only) has it on the wire before its record is saved; "final" has the final
\* answer saved and the turn not yet committed; "tools" runs the turn's tool
\* calls between requests; "ask" shows a question at launch; "held" has the
\* turn stopped at its save before a send while a restart waits (Hold).
PCs == {"off", "idle", "ask", "save", "flight", "late", "wait", "need",
        "tools", "final", "held"}
Questions == {"none", "crash", "old", "other"}

ProcStates == [pc: PCs, req: 0..MaxReq, cont: BOOLEAN, md: 0..CrashLoopAfter,
               q: Questions, auto: BOOLEAN, old: BOOLEAN, fresh: BOOLEAN]
OffProc == [pc |-> "off", req |-> 0, cont |-> FALSE, md |-> 0, q |-> "none",
            auto |-> FALSE, old |-> FALSE, fresh |-> FALSE]
Idle(r) == [OffProc EXCEPT !.pc = "idle", !.req = r]

VARIABLES
    turn,      \* the newest turn in the session log
    lock,      \* the processes holding the writer lock
    wall,      \* the wall clock, in days
    \* Each process: pc, the request it works on (req), whether its next
    \* save writes a new turn (cont), the module's abrupt-death count in
    \* memory (md), the question it shows (q), whether its current request
    \* was sent again by a launch with no user input (auto), whether that
    \* launch found a record from an earlier day (old), and whether its next
    \* save records the user's answer to the crash-loop question (fresh).
    ps,
    \* The world and what the rules read.
    faults,    \* disruptions injected so far
    fate,      \* what became of each request
    answered,  \* the request's final answer was saved
    seen,      \* deaths with the current model request's send in flight
    stranded,  \* a launch left a request it could have resumed
    \* Ctrl+G: whether a restart waits for the running turn to stop
    \* (pending), whether the process holds the relaunch it prepared
    \* (armed), the request a relaunch left for the next launch to
    \* continue, 0 for none (yielded), whether a launch failed to continue
    \* one (lost), and whether an exit after a cancelled restart relaunched
    \* (stray).
    up,
    \* history: a resumed request's send wrote a turn that does not keep the
    \* stopped turn's work, so the log shows the request as two turns.
    split

vars == <<turn, lock, wall, ps, faults, fate, answered, seen, stranded, up, split>>

NoUpgrade == [pending |-> FALSE, armed |-> FALSE, yielded |-> 0, lost |-> FALSE,
              stray |-> FALSE]

TypeOK ==
    /\ turn \in Turns /\ lock \subseteq Procs /\ wall \in Days
    /\ ps \in [Procs -> ProcStates]
    /\ faults \in 0..MaxFaults
    /\ fate \in [Reqs -> {"none", "open", "ok", "cancel"}]
    /\ answered \in [Reqs -> BOOLEAN]
    /\ seen \in 0..CrashLoopAfter
    /\ stranded \in BOOLEAN
    /\ up \in [pending: BOOLEAN, armed: BOOLEAN, yielded: 0..MaxReq,
               lost: BOOLEAN, stray: BOOLEAN]
    /\ split \in BOOLEAN

-----------------------------------------------------------------------------
(* Derived values.                                                         *)

Today    == Policy = "today"
Proposed == Policy = "proposed"
CanFault == faults < MaxFaults
Holds(p) == p \in lock
Cur      == turn.req

\* A resumed request continues the stopped turn: the same request, and the
\* turn a crash ended, or the open turn a question wrote for it. Its send
\* keeps the stopped turn's work. Planted defect note_turn: the send starts
\* a fresh turn with no work, as the CLI's old <session_resumed> note did.
\* A request whose final answer was saved is not resumed (the launch does
\* not send it, as resumable says); a user's continue of it starts a new turn.
Resumed(p) == ps[p].cont /\ turn.req = ps[p].req /\ turn.st \in {"crash", "open"}
              /\ turn.work # "final"
KeptWork(p) == IF Resumed(p) /\ Bug # "note_turn" THEN turn.work ELSE "none"

\* The turn a save writes: a new one, or the newest with the record replaced.
Written(p, r) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "open", rec |-> r, work |-> KeptWork(p), at |-> wall]
       ELSE [turn EXCEPT !.rec = r, !.at = wall]

\* A save that resumes a stopped turn splits it when it does not keep the
\* turn's work.
Splits(p) == Resumed(p) /\ Written(p, NoRec).work # turn.work

\* A module is running a request: closing saves its record.
ModuleActive(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need"}
OnWire(p) == ps[p].pc \in {"flight", "late"}

\* The record a send saves, carrying the module's count. Planted defect
\* reset_on_resume: the count a resume started from is not saved.
SendRec(p) == [ph |-> "sending", clean |-> FALSE, need |-> "none",
               deaths |-> IF Bug = "reset_on_resume" THEN 0 ELSE ps[p].md]

\* recovery.zig resumeFrom: the abrupt-death count after reading r.
Count(r) == Min(r.deaths + (IF r.ph = "sending" /\ ~r.clean THEN 1 ELSE 0),
                CrashLoopAfter)

\* A finished request clears its record. Planted defect no_clear: it is left.
Cleared == IF Bug = "no_clear" THEN turn.rec ELSE NoRec

NextReq == Cardinality({r \in Reqs : fate[r] # "none"}) + 1

-----------------------------------------------------------------------------
(* Launch.                                                                 *)

Init ==
    /\ turn = NoTurn /\ lock = {} /\ wall = 0
    /\ ps = [p \in Procs |-> OffProc]
    /\ faults = 0 /\ fate = [r \in Reqs |-> "none"]
    /\ answered = [r \in Reqs |-> FALSE] /\ seen = 0 /\ stranded = FALSE
    /\ up = NoUpgrade
    /\ split = FALSE

\* The launch opens the session, the manager ends an open turn as a crash,
\* and fx decides whether to continue it. Planted defect no_lock: a second
\* process opens a session another holds.
Launch(p) ==
    LET t == [turn EXCEPT !.st = IF @ = "open" THEN "crash" ELSE @]
        resumable ==
            /\ t.req > 0
            /\ \/ t.st = "crash"
               \* Planted defect resume_cancelled: a turn the user cancelled
               \* resumes too.
               \/ Bug = "resume_cancelled" /\ t.st = "cancel"
            \* Planted defect resume_answered: so does one whose final
            \* answer was saved.
            /\ t.work # "final" \/ Bug = "resume_answered"
        isOld == t.at # wall
        asksOld == isOld /\ Bug # "ignore_age"
        c == Count(t.rec)
        \* A question writes the turn that continues the request at once, so
        \* Esc there ends it. A send writes it with the send's record; a death
        \* before that reads the same record again.
        ask(q) == /\ turn' = [req |-> t.req, st |-> "open", work |-> t.work, at |-> wall,
                              rec |-> [ph |-> "need", clean |-> FALSE, deaths |-> c, need |-> q]]
                  /\ ps' = [ps EXCEPT ![p] = [pc |-> "ask", req |-> t.req, cont |-> FALSE,
                                              md |-> c, q |-> q, auto |-> FALSE, old |-> isOld,
                                              fresh |-> FALSE]]
    IN
    /\ ps[p].pc = "off"
    /\ lock = {} \/ Bug = "no_lock"
    /\ lock' = lock \cup {p}
    /\ IF ~resumable \/ Today
          THEN /\ turn' = t
               /\ ps' = [ps EXCEPT ![p] = Idle(t.req)]
               /\ stranded' = (stranded \/ (resumable /\ ~isOld))
          ELSE /\ UNCHANGED stranded
               /\ CASE asksOld                   -> ask("old")
                    [] c >= CrashLoopAfter       -> ask("crash")
                    [] t.rec.ph = "need"         -> ask(t.rec.need)
                    [] OTHER ->
                         /\ turn' = t
                         /\ ps' = [ps EXCEPT ![p] = [pc |-> "save", req |-> t.req,
                                       cont |-> TRUE, md |-> c, q |-> "none",
                                       auto |-> TRUE, old |-> isOld, fresh |-> FALSE]]
    \* A relaunch's request goes on in this launch, at once or after asking.
    /\ up' = [up EXCEPT !.yielded = 0,
                        !.lost = @ \/ (up.yielded # 0 /\ ~(resumable /\ t.req = up.yielded))]
    /\ UNCHANGED <<wall, faults, fate, answered, seen, split>>

-----------------------------------------------------------------------------
(* The user.                                                               *)

\* A new message, written to the log with its first send. A request left
\* interrupted is given up. While a restart waits, fx holds it.
Prompt(p) ==
    LET r == NextReq IN
    /\ ps[p].pc = "idle" /\ Holds(p) /\ r <= MaxReq /\ ~up.pending
    /\ fate' = [fate EXCEPT ![r] = "open",
                            ![Cur] = IF Cur > 0 /\ @ = "open" THEN "cancel" ELSE @]
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = r, !.cont = TRUE]]
    /\ seen' = 0
    /\ UNCHANGED <<turn, lock, wall, faults, answered, stranded, up, split>>

\* "continue" after a launch that did not resume: a new turn for the same
\* request, sent because the user asked, even when its answer was saved.
UserContinue(p) ==
    /\ ps[p].pc = "idle" /\ Holds(p) /\ ~up.pending
    /\ Cur > 0 /\ turn.st = "crash" /\ fate[Cur] = "open"
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = Cur,
                                               !.cont = TRUE, !.md = Count(turn.rec)]]
    /\ answered' = [answered EXCEPT ![Cur] = FALSE]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, seen, stranded, up, split>>

\* Enter at a question, or after fixing what a request waits on: send again.
\* Answering the crash-loop question starts the count over (recovery.zig
\* onUserContinue), once the send's save records it.
Enter(p) ==
    LET loop == ps[p].q = "crash" IN
    /\ ps[p].pc \in {"ask", "need"}
    /\ ps' = [ps EXCEPT ![p].pc = "save", ![p].q = "none", ![p].auto = FALSE,
                        ![p].md = IF loop THEN 0 ELSE @, ![p].fresh = loop]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded, up, split>>

\* The request ends as cancelled: its turn, written now if it was not yet.
Cancelled(p) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "cancel", rec |-> NoRec, work |-> KeptWork(p), at |-> wall]
       ELSE [turn EXCEPT !.st = "cancel", !.rec = NoRec]

\* Esc: the request ends, and nothing resumes it.
Esc(p) ==
    /\ ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need", "held"}
    /\ turn' = Cancelled(p)
    /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
    /\ ps' = [ps EXCEPT ![p] = Idle(ps[p].req)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded, up, split>>

\* An exit other than the restart: the relaunch it prepared is dropped
\* while the restart still waits (auto_upgrade.zig takeRelaunchRequest);
\* one that is still held after the restart stopped waiting relaunches.
ExitUp == [up EXCEPT !.pending = FALSE, !.armed = FALSE,
                     !.stray = @ \/ (up.armed /\ ~up.pending)]

\* /quit cancels a running request first, as Esc does; a turn whose answer
\* is saved commits. A restart that waited goes with the process.
Quit(p) ==
    LET pc == ps[p].pc IN
    /\ pc # "off"
    /\ CASE pc = "final" ->
              /\ turn' = [turn EXCEPT !.st = "done", !.rec = NoRec]
              /\ fate' = [fate EXCEPT ![Cur] = "ok"]
         [] pc \in {"ask", "save", "flight", "late", "wait", "need", "tools", "held"} ->
              /\ turn' = Cancelled(p)
              /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
         [] OTHER -> UNCHANGED <<turn, fate>>
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ seen' = IF pc \in {"idle", "off"} THEN seen ELSE 0
    /\ up' = ExitUp
    /\ UNCHANGED <<wall, faults, answered, stranded, split>>

-----------------------------------------------------------------------------
(* fx's own steps.                                                         *)

\* Save the record and send. Today saves nothing. Planted defect
\* send_before_save: the send goes out first. While a restart waits, a
\* turn already in the log stops here instead (Hold).
Save(p) ==
    /\ ps[p].pc = "save" /\ Holds(p)
    /\ ~(up.pending /\ (~ps[p].cont \/ Bug = "yield_first"))
    /\ IF Bug = "send_before_save"
          THEN /\ ps' = [ps EXCEPT ![p].pc = "late"]
               /\ UNCHANGED <<turn, split>>
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
               /\ turn' = Written(p, IF Today THEN NoRec ELSE SendRec(p))
               /\ split' = (split \/ Splits(p))
    /\ seen' = IF ps[p].fresh /\ Bug # "send_before_save" THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded, up>>

LateSave(p) ==
    /\ ps[p].pc = "late"
    /\ turn' = Written(p, SendRec(p))
    /\ split' = (split \/ Splits(p))
    /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
    /\ seen' = IF ps[p].fresh THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded, up>>

\* The response arrives whole: tool calls to run, or the final answer. The
\* request is finished, so its record is cleared before the response's
\* pieces are saved: a death after this is not a death in flight.
Respond(p) ==
    /\ ps[p].pc = "flight"
    /\ \/ /\ turn' = [turn EXCEPT !.work = "tools", !.rec = Cleared]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "tools", !.md = 0,
                                               !.auto = FALSE]]
          /\ UNCHANGED answered
       \/ /\ turn' = [turn EXCEPT !.work = "final", !.rec = Cleared]
          /\ answered' = [answered EXCEPT ![Cur] = TRUE]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "final", !.auto = FALSE]]
    \* The model request that crashed fx got its answer.
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, fate, stranded, up, split>>

\* The turn with the final answer commits.
Finish(p) ==
    /\ ps[p].pc = "final"
    /\ turn' = [turn EXCEPT !.st = "done"]
    /\ fate' = [fate EXCEPT ![Cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p] = Idle(Cur)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded, up, split>>

\* The tools finish and the turn's next request starts with a new module.
ToolsDone(p) ==
    /\ ps[p].pc = "tools"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded, up, split>>

\* A failure the module waits out, and the retry when the wait ends.
Fail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "waiting"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "wait"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded, up, split>>

Retry(p) ==
    /\ ps[p].pc = "wait"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded, up, split>>

\* A failure only the user can fix, such as an expired sign-in.
NeedFail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "need",
                                                          !.need = "other"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "need", ![p].q = "other"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded, up, split>>

-----------------------------------------------------------------------------
(* The world.                                                              *)

\* SIGKILL or a crash. The open turn stays open.
Kill(p) ==
    /\ ps[p].pc # "off" /\ CanFault
    /\ seen' = IF OnWire(p) THEN Min(seen + 1, CrashLoopAfter) ELSE seen
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ up' = [up EXCEPT !.pending = FALSE, !.armed = FALSE]
    /\ UNCHANGED <<turn, wall, fate, answered, stranded, split>>

\* SIGHUP, SIGTERM, or a terminal that hangs up. fx saves the running
\* module's record marked clean in its turn and leaves the turn open; it
\* never ends the turn as cancelled. With no request running, or none of its
\* turn written yet, nothing is saved. Today, and planted defect no_closing,
\* die as a kill does. A close is not a death: `seen` stays.
Close(p) ==
    LET saves == Proposed /\ Bug # "no_closing" /\ ModuleActive(p) /\ ~ps[p].cont IN
    /\ ps[p].pc # "off" /\ CanFault
    /\ turn' = IF saves
                  THEN [turn EXCEPT
                          !.rec = IF ps[p].pc \in {"save", "late"}
                                     THEN [SendRec(p) EXCEPT !.clean = TRUE]
                                     ELSE [@ EXCEPT !.clean = TRUE],
                          !.at = wall]
                  ELSE turn
    \* The save records an answer to the crash-loop question too.
    /\ seen' = IF saves /\ ps[p].fresh THEN 0 ELSE seen
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ up' = ExitUp
    /\ UNCHANGED <<wall, fate, answered, stranded, split>>

\* A day passes.
Day ==
    /\ wall = 0 /\ CanFault
    /\ wall' = 1
    /\ faults' = faults + 1
    /\ UNCHANGED <<turn, lock, ps, fate, answered, seen, stranded, up, split>>

-----------------------------------------------------------------------------
(* Ctrl+G.                                                                 *)

\* An upgrade is ready and the user presses Ctrl+G. fx refuses while the
\* request asks or waits for the user; otherwise the restart waits for the
\* running turn to stop (app_upgrade_runtime.zig). Under "today", fx
\* before its recovery records refused while a turn ran, so only the
\* proposed design has this step.
Upgrade(p) ==
    /\ Proposed /\ ~up.pending /\ Holds(p)
    /\ ps[p].pc \in {"idle", "save", "flight", "late", "wait", "tools", "final"}
    /\ up' = [up EXCEPT !.pending = TRUE, !.armed = TRUE]
    /\ UNCHANGED <<turn, lock, wall, ps, faults, fate, answered, seen, stranded, split>>

\* The turn stops at its save before a model request once the turn is in
\* the log (quiesce.zig), and holds there while the restart waits
\* (orchestrator.zig yieldTurn, WorkerRuntime.holdForRestart). The save
\* records the module's state marked clean, as a close does, and the turn
\* stays open with the yield marker for the next launch to continue.
\* Planted defect yield_unclean: the record is saved as a death. Planted
\* defect yield_first: the turn stops at its prompt's first send, before
\* it reaches the log.
Hold(p) ==
    LET saves == ~ps[p].cont IN
    /\ up.pending /\ Holds(p)
    /\ ps[p].pc = "save" /\ (saves \/ Bug = "yield_first")
    /\ turn' = IF saves
                  THEN [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.clean = Bug # "yield_unclean"],
                                    !.at = wall]
                  ELSE turn
    \* The save records an answer to the crash-loop question too.
    /\ seen' = IF saves /\ ps[p].fresh THEN 0 ELSE seen
    /\ ps' = [ps EXCEPT ![p].pc = "held", ![p].fresh = FALSE]
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded, up, split>>

\* The restart: with nothing running, or with the turn held, whose record
\* and marker are already saved, so it writes nothing more.
Relaunch(p) ==
    LET held == ps[p].pc = "held" IN
    /\ up.pending /\ Holds(p) /\ CanFault
    /\ ps[p].pc \in {"idle", "held"}
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ up' = [up EXCEPT !.pending = FALSE, !.armed = FALSE,
                        !.yielded = IF held THEN ps[p].req ELSE 0]
    /\ UNCHANGED <<turn, wall, fate, answered, seen, stranded, split>>

\* A second Ctrl+G while the restart waits cancels it: the relaunch it
\* prepared is dropped (auto_upgrade.zig cancelRestart), and a held turn
\* goes on to its send, which saves the send's record again first, as
\* every send does (Save, request_recovery.zig reopenAfterYield). Planted
\* defect cancel_strands: the held turn stays stopped. Planted defect
\* cancel_keeps_relaunch: the prepared relaunch stays. Planted defect
\* cancel_unsaved: the held turn sends with its clean record.
CancelRestart(p) ==
    /\ up.pending /\ Holds(p)
    /\ ps' = IF ps[p].pc = "held" /\ Bug # "cancel_strands"
                THEN [ps EXCEPT ![p].pc = IF Bug = "cancel_unsaved" THEN "flight" ELSE "save"]
                ELSE ps
    /\ up' = [up EXCEPT !.pending = FALSE,
                        !.armed = IF Bug = "cancel_keeps_relaunch" THEN @ ELSE FALSE]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded, split>>

\* The restart's save does not land, as a failed disk write can make it:
\* the turn goes on, and its send goes out with the record of a send in
\* flight that its earlier write left, as Save does. The restart still
\* waits, and the next save asks again (orchestrator.zig yieldTurn,
\* request_recovery.zig closeForYield). Planted defect yield_unsaved: the
\* turn stops anyway and is marked yielded, so the next launch reads a
\* send in flight and counts a death that no crash caused.
YieldSaveFails(p) ==
    /\ Proposed /\ up.pending /\ Holds(p) /\ CanFault
    /\ ps[p].pc = "save" /\ ~ps[p].cont
    /\ turn' = Written(p, SendRec(p))
    /\ seen' = IF ps[p].fresh THEN 0 ELSE seen
    /\ faults' = faults + 1
    /\ IF Bug = "yield_unsaved"
          THEN /\ ps' = [ps EXCEPT ![p] = OffProc]
               /\ lock' = lock \ {p}
               /\ up' = [up EXCEPT !.pending = FALSE, !.armed = FALSE, !.yielded = ps[p].req]
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
               /\ UNCHANGED <<lock, up>>
    /\ UNCHANGED <<wall, fate, answered, stranded, split>>

Next ==
    \/ \E p \in Procs :
          \/ Launch(p) \/ Prompt(p) \/ UserContinue(p) \/ Enter(p) \/ Esc(p)
          \/ Quit(p) \/ Save(p) \/ LateSave(p) \/ Respond(p) \/ Finish(p)
          \/ ToolsDone(p) \/ Fail(p) \/ Retry(p) \/ NeedFail(p)
          \/ Kill(p) \/ Close(p) \/ Upgrade(p) \/ Hold(p) \/ Relaunch(p)
          \/ CancelRestart(p) \/ YieldSaveFails(p)
    \/ Day

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* The request on the wire was sent again by a launch, with no user input.
AutoSend(p) == ps[p].auto /\ ps[p].pc \in {"save", "flight", "late"}

\* A launch that finds a request a kill, a crash, or a close interrupted
\* sends it again on its own, unless the module must ask first.
AutoResumes == ~stranded

\* A close is not a crash: the crash-loop question needs two deaths with the
\* request's send in flight.
NoFalseCrashQuestion == \A p \in Procs : ps[p].q = "crash" => seen >= CrashLoopAfter

\* A request that crashed fx twice with its send in flight is not sent again
\* without asking.
CrashLoopAsks == \A p \in Procs : AutoSend(p) => seen < CrashLoopAfter

\* A request whose final answer was saved is never sent again on its own.
DoneNeverResent == \A p \in Procs : AutoSend(p) => ~answered[ps[p].req]

\* A request the user cancelled or gave up is never sent again on its own.
CancelNeverResumes == \A p \in Procs : AutoSend(p) => fate[ps[p].req] # "cancel"

\* A request interrupted on an earlier day is sent again only after asking.
OldAsks == \A p \in Procs : AutoSend(p) => ~ps[p].old

\* A resumed request continues the stopped turn: the log holds one turn for
\* the request, with the work the stopped turn had.
SameTurn == ~split

\* One session, one process working on its request.
Working(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need",
                             "tools", "final", "held"}
OneWorker == Cardinality({p \in Procs : Working(p)}) <= 1

\* A turn that stopped for an upgrade's restart goes on at the next launch:
\* its request is still the newest turn's, and the launch continues it.
YieldContinues == ~up.lost

\* A turn holds for an upgrade's restart only while the restart waits: a
\* cancelled restart leaves no turn stopped.
HeldOnlyWhileRestartWaits == \A p \in Procs : ps[p].pc = "held" => up.pending

\* An exit after a cancelled restart is a plain exit, not the restart.
CancelledRestartStays == ~up.stray

=============================================================================
