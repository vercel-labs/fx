------------------------------- MODULE Resume -------------------------------
(***************************************************************************)
(* How fx resumes a turn after fx dies, is closed, or restarts for an      *)
(* upgrade in the middle of a turn.                                        *)
(*                                                                         *)
(* Recovery.tla models the recovery module inside one fx process. This     *)
(* model takes the module's resume decision as given (recovery.zig         *)
(* resumeFrom) and checks what surrounds it: two fx processes that can     *)
(* open one session, the user, the session log they share, and the ways a  *)
(* process ends.                                                           *)
(*                                                                         *)
(* The log is reduced to its newest turn: the request it serves, how it    *)
(* ended, the newest `recovery` piece it holds (the module's record),      *)
(* whether it was marked yielded, its saved abrupt-death count, and what   *)
(* its other pieces show. A turn that is still open when a launch opens    *)
(* the session is ended `crash` by the session manager. The writer lock    *)
(* lets one process write the session.                                     *)
(*                                                                         *)
(* A process ends in one of four ways:                                     *)
(* - Quit: /quit or Ctrl+C twice. It cancels the request first, as Esc     *)
(*   does, so nothing resumes.                                             *)
(* - Close: SIGHUP or SIGTERM, from a closed window, a logout, or a        *)
(*   reboot. A closed window can reach fx as its terminal hanging up       *)
(*   before SIGHUP, and closes fx the same way. fx saves the running       *)
(*   module's record marked clean, or closes the open turn cleanly, and    *)
(*   exits. A close does not count as a crash.                             *)
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
(*   when the request's response arrives. Resume never asks for a crash or *)
(*   for age. A launch that finds a turn ended by a crash computes         *)
(*   n = saved count + 1. If n >= CrashLoopAfter, the turn ends as         *)
(*   stopped with a plain notice, nothing is sent or rerun, and nothing    *)
(*   asks. Otherwise the turn continues at once as the same turn, and n    *)
(*   reaches the log in the continuation's first write before any rerun or *)
(*   send. A close-ended or yielded turn continues with its count          *)
(*   unchanged. A question the record was already waiting on ("other":     *)
(*   sign-in, quota, and the like) is still shown again on launch.         *)
(*                                                                         *)
(* A save and the send it goes with are one step: the record cannot tell a *)
(* send that was saved but not yet sent from one on the wire, so a death   *)
(* in that window counts as a crash.                                       *)
(*                                                                         *)
(* Bug plants one defect in the proposed design. Each config names the one *)
(* rule that must catch it.                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Policy,     \* "today" or "proposed"
    MaxReq,     \* requests the user may send in the session
    MaxFaults,  \* disruptions: kills, closes, failures
    Bug         \* "none", or the name of one planted defect

Bugs == {"none", "no_closing", "no_clear", "send_before_save",
         "reset_on_resume", "resume_answered", "resume_cancelled",
         "no_lock", "yield_unclean", "yield_first",
         "yield_unsaved", "note_turn", "cancel_strands",
         "cancel_keeps_relaunch", "cancel_unsaved",
         "guard_asks", "no_guard", "tool_death_uncounted",
         "rerun_death_uncounted"}

Procs == {1, 2}
Reqs  == 1..MaxReq

ASSUME /\ Policy \in {"today", "proposed"}
       /\ MaxReq \in Nat \ {0} /\ MaxFaults \in Nat
       /\ Bug \in Bugs
       /\ Bug # "none" => Policy = "proposed"

CrashLoopAfter == 3   \* recovery.zig crash_loop_after

Min(a, b) == IF a < b THEN a ELSE b

\* The newest `recovery` piece of the turn, reduced to what a launch reads.
\* ph "none" is no piece, or one a finished request wrote to clear it.
\* need names the question a `need` record waits on.
RecPhases == {"none", "sending", "waiting", "need"}
Needs     == {"none", "other"}
Records   == [ph: RecPhases, clean: BOOLEAN, need: Needs]
NoRec     == [ph |-> "none", clean |-> FALSE, need |-> "none"]

\* How the newest turn ended. "open" has no end yet; "stopped" ended at the
\* crash-loop guard and is not resumable.
TurnEnds == {"open", "done", "cancel", "crash", "closed", "stopped"}
\* What the turn's other pieces show after its newest finished request:
\* nothing yet, tool calls or results the model has not seen, or the final
\* answer.
Works == {"none", "tools", "final"}
Turns == [req: 0..MaxReq, st: TurnEnds, rec: Records, work: Works,
          crashes: 0..CrashLoopAfter, yield: BOOLEAN]
NoTurn == [req |-> 0, st |-> "done", rec |-> NoRec, work |-> "none",
           crashes |-> 0, yield |-> FALSE]

\* What a process is doing. "save" has the module started and about to save
\* and send (or rerun first); "rerun" runs a safe call before the first send;
\* "flight" has that send on the wire; "late" (send_before_save only) has it
\* on the wire before its record is saved; "final" has the final answer saved
\* and the turn not yet committed; "tools" runs the turn's tool calls between
\* requests; "ask" shows a question at launch; "held" has the turn stopped at
\* its save before a send while a restart waits (Hold).
PCs == {"off", "idle", "ask", "save", "rerun", "flight", "late", "wait",
        "need", "tools", "final", "held"}
Questions == {"none", "crash", "other"}

ProcStates == [pc: PCs, req: 0..MaxReq, cont: BOOLEAN, md: 0..CrashLoopAfter,
               q: Questions, auto: BOOLEAN]
OffProc == [pc |-> "off", req |-> 0, cont |-> FALSE, md |-> 0, q |-> "none",
            auto |-> FALSE]
Idle(r) == [OffProc EXCEPT !.pc = "idle", !.req = r]

VARIABLES
    turn,      \* the newest turn in the session log
    lock,      \* the processes holding the writer lock
    \* Each process: pc, the request it works on (req), whether its next
    \* save writes a new turn (cont), the abrupt-death count in memory (md),
    \* the question it shows (q), and whether its current request was sent
    \* again by a launch with no user input (auto).
    ps,
    \* The world and what the rules read.
    faults,    \* disruptions injected so far
    fate,      \* what became of each request
    answered,  \* the request's final answer was saved
    deaths,    \* world truth: abrupt deaths per turn (indexed by request)
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

vars == <<turn, lock, ps, faults, fate, answered, deaths, stranded, up, split>>

NoUpgrade == [pending |-> FALSE, armed |-> FALSE, yielded |-> 0, lost |-> FALSE,
              stray |-> FALSE]

TypeOK ==
    /\ turn \in Turns /\ lock \subseteq Procs
    /\ ps \in [Procs -> ProcStates]
    /\ faults \in 0..MaxFaults
    /\ fate \in [Reqs -> {"none", "open", "ok", "cancel"}]
    /\ answered \in [Reqs -> BOOLEAN]
    /\ deaths \in [Reqs -> 0..CrashLoopAfter]
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
\* turn a crash or close ended, or the open turn a question wrote for it. Its
\* send keeps the stopped turn's work. Planted defect note_turn: the send
\* starts a fresh turn with no work, as the CLI's old <session_resumed> note
\* did. A request whose final answer was saved is not resumed.
Resumed(p) == ps[p].cont /\ turn.req = ps[p].req
              /\ turn.st \in {"crash", "closed", "open"}
              /\ turn.work # "final"
KeptWork(p) == IF Resumed(p) /\ Bug # "note_turn" THEN turn.work ELSE "none"

\* The count a write records in the log. Planted defect reset_on_resume:
\* the count a resume started from is not saved.
SavedCrashes(p) == IF Bug = "reset_on_resume" THEN 0 ELSE ps[p].md

\* The turn a save writes: a new continuation, or the newest with the record
\* and count updated.
Written(p, r) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "open", rec |-> r, work |-> KeptWork(p),
             crashes |-> SavedCrashes(p), yield |-> FALSE]
       ELSE [turn EXCEPT !.rec = r, !.crashes = SavedCrashes(p), !.yield = FALSE]

\* A save that resumes a stopped turn splits it when it does not keep the
\* turn's work.
Splits(p) == Resumed(p) /\ Written(p, NoRec).work # turn.work

\* A module is running a request: closing saves its record.
ModuleActive(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need"}

\* A finished request clears its record. Planted defect no_clear: it is left.
Cleared == IF Bug = "no_clear" THEN turn.rec ELSE NoRec

NextReq == Cardinality({r \in Reqs : fate[r] # "none"}) + 1

-----------------------------------------------------------------------------
(* Launch.                                                                 *)

\* The launch opens the session, the manager ends an open turn as a crash,
\* and fx decides whether to continue it. Planted defect no_lock: a second
\* process opens a session another holds.
Launch(p) ==
    LET t == [turn EXCEPT !.st = IF @ = "open" THEN "crash" ELSE @]
        resumable ==
            /\ t.req > 0
            /\ \/ t.st \in {"crash", "closed"}
               \* Planted defect resume_cancelled: a turn the user cancelled
               \* resumes too.
               \/ Bug = "resume_cancelled" /\ t.st = "cancel"
            \* Planted defect resume_answered: so does one whose final
            \* answer was saved.
            /\ t.work # "final" \/ Bug = "resume_answered"
        \* A crash adds 1 unless the turn was yielded or closed. Planted
        \* defect tool_death_uncounted: only a death with a send in flight
        \* counts, as the old module did.
        isCrash ==
            /\ t.st = "crash"
            /\ ~t.yield
            /\ (Bug # "tool_death_uncounted" \/ (t.rec.ph = "sending" /\ ~t.rec.clean))
        c == Min(t.crashes + (IF isCrash THEN 1 ELSE 0), CrashLoopAfter)
        atGuard == c >= CrashLoopAfter /\ Bug # "no_guard"
        \* A question the record was already waiting on ("other") is shown
        \* again on launch.
        ask(q) == /\ turn' = [req |-> t.req, st |-> "open", work |-> t.work,
                              crashes |-> c, yield |-> FALSE,
                              rec |-> [ph |-> "need", clean |-> FALSE,
                                       need |-> IF q = "crash" THEN "none" ELSE q]]
                  /\ ps' = [ps EXCEPT ![p] = [pc |-> "ask", req |-> t.req, cont |-> FALSE,
                                              md |-> c, q |-> q, auto |-> FALSE]]
    IN
    /\ ps[p].pc = "off"
    /\ lock = {} \/ Bug = "no_lock"
    /\ lock' = lock \cup {p}
    /\ IF ~resumable \/ Today
          THEN /\ turn' = t
               /\ ps' = [ps EXCEPT ![p] = Idle(t.req)]
               /\ stranded' = (stranded \/ resumable)
          ELSE /\ UNCHANGED stranded
               /\ CASE atGuard /\ Bug = "guard_asks" -> ask("crash")
                    [] atGuard ->
                         /\ turn' = [t EXCEPT !.st = "stopped", !.rec = NoRec, !.crashes = c]
                         /\ ps' = [ps EXCEPT ![p] = Idle(t.req)]
                    [] t.rec.ph = "need" -> ask(t.rec.need)
                    [] OTHER ->
                         /\ turn' = t
                         /\ ps' = [ps EXCEPT ![p] = [pc |-> "save", req |-> t.req,
                                       cont |-> TRUE, md |-> c, q |-> "none",
                                       auto |-> TRUE]]
    \* A relaunch's request goes on in this launch.
    /\ up' = [up EXCEPT !.yielded = 0,
                        !.lost = @ \/ (up.yielded # 0 /\ ~(resumable /\ t.req = up.yielded))]
    /\ UNCHANGED <<faults, fate, answered, deaths, split>>

-----------------------------------------------------------------------------
(* The user.                                                               *)

\* A new message, written to the log with its first send. A request left
\* interrupted is given up. While a restart waits, fx holds it.
Prompt(p) ==
    LET r == NextReq IN
    /\ ps[p].pc = "idle" /\ Holds(p) /\ r <= MaxReq /\ ~up.pending
    /\ fate' = IF Cur > 0 /\ fate[Cur] = "open"
                  THEN [fate EXCEPT ![r] = "open", ![Cur] = "cancel"]
                  ELSE [fate EXCEPT ![r] = "open"]
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = r, !.cont = TRUE]]
    /\ UNCHANGED <<turn, lock, faults, answered, deaths, stranded, up, split>>

\* "continue" after a launch that did not resume (Today only): a new turn for
\* the same request, sent because the user asked.
UserContinue(p) ==
    /\ Today /\ ps[p].pc = "idle" /\ Holds(p) /\ ~up.pending
    /\ Cur > 0 /\ turn.st = "crash" /\ fate[Cur] = "open"
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = Cur,
                                               !.cont = TRUE, !.md = turn.crashes]]
    /\ answered' = [answered EXCEPT ![Cur] = FALSE]
    /\ UNCHANGED <<turn, lock, faults, fate, deaths, stranded, up, split>>

\* Enter after fixing what a request waits on: send again.
Enter(p) ==
    /\ ps[p].pc \in {"ask", "need"}
    /\ ps' = [ps EXCEPT ![p].pc = "save", ![p].q = "none", ![p].auto = FALSE]
    /\ UNCHANGED <<turn, lock, faults, fate, answered, deaths, stranded, up, split>>

\* The request ends as cancelled: its turn, written now if it was not yet.
Cancelled(p) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "cancel", rec |-> NoRec, work |-> KeptWork(p),
             crashes |-> SavedCrashes(p), yield |-> FALSE]
       ELSE [turn EXCEPT !.st = "cancel", !.rec = NoRec, !.yield = FALSE]

\* Esc: the request ends, and nothing resumes it.
Esc(p) ==
    /\ ps[p].pc \in {"ask", "save", "rerun", "flight", "late", "wait", "need", "held"}
    /\ turn' = Cancelled(p)
    /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
    /\ ps' = [ps EXCEPT ![p] = Idle(ps[p].req)]
    /\ UNCHANGED <<lock, faults, answered, deaths, stranded, up, split>>

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
         [] pc \in {"ask", "save", "rerun", "flight", "late", "wait", "need", "tools", "held"} ->
              /\ turn' = Cancelled(p)
              /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
         [] OTHER -> UNCHANGED <<turn, fate>>
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ up' = ExitUp
    /\ UNCHANGED <<faults, answered, deaths, stranded, split>>

-----------------------------------------------------------------------------
(* fx's own steps.                                                         *)

\* Optional rerun of a safe call before the continuation's first send.
\* The continuation's count reaches the log in the first write before any
\* rerun or send. Planted defect rerun_death_uncounted: the count reaches
\* the log only with the first send, after the rerun.
Rerun(p) ==
    /\ Proposed /\ ps[p].pc = "save" /\ ps[p].cont /\ Holds(p) /\ ~up.pending
    /\ turn.req = ps[p].req /\ turn.st \in {"crash", "closed"}
    /\ IF Bug = "rerun_death_uncounted"
          THEN /\ UNCHANGED <<turn, split>>
               /\ ps' = [ps EXCEPT ![p].pc = "rerun"]
          ELSE /\ turn' = Written(p, NoRec)
               /\ split' = (split \/ Splits(p))
               /\ ps' = [ps EXCEPT ![p].pc = "rerun", ![p].cont = FALSE]
    /\ UNCHANGED <<lock, faults, fate, answered, deaths, stranded, up>>

RerunDone(p) ==
    /\ ps[p].pc = "rerun"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, faults, fate, answered, deaths, stranded, up, split>>

\* Save the record and send. Today saves nothing. Planted defect
\* send_before_save: the send goes out first. While a restart waits, a
\* turn already in the log stops here instead (Hold).
Save(p) ==
    /\ ps[p].pc = "save" /\ Holds(p)
    /\ ~(up.pending /\ (~ps[p].cont \/ Bug = "yield_first"))
    /\ IF Bug = "send_before_save"
          THEN /\ ps' = [ps EXCEPT ![p].pc = "late"]
               /\ UNCHANGED <<turn, split>>
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE]
               /\ turn' = Written(p, IF Today THEN NoRec ELSE
                                     [ph |-> "sending", clean |-> FALSE, need |-> "none"])
               /\ split' = (split \/ Splits(p))
    /\ UNCHANGED <<lock, faults, fate, answered, deaths, stranded, up>>

LateSave(p) ==
    /\ ps[p].pc = "late"
    /\ turn' = Written(p, [ph |-> "sending", clean |-> FALSE, need |-> "none"])
    /\ split' = (split \/ Splits(p))
    /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE]
    /\ UNCHANGED <<lock, faults, fate, answered, deaths, stranded, up>>

\* The response arrives whole: tool calls to run, or the final answer. The
\* request is finished, so its record is cleared before the response's
\* pieces are saved.
Respond(p) ==
    /\ ps[p].pc = "flight"
    /\ \/ /\ turn' = [turn EXCEPT !.work = "tools", !.rec = Cleared]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "tools", !.auto = FALSE]]
          /\ UNCHANGED answered
       \/ /\ turn' = [turn EXCEPT !.work = "final", !.rec = Cleared]
          /\ answered' = [answered EXCEPT ![Cur] = TRUE]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "final", !.auto = FALSE]]
    /\ UNCHANGED <<lock, faults, fate, deaths, stranded, up, split>>

\* The turn with the final answer commits.
Finish(p) ==
    /\ ps[p].pc = "final"
    /\ turn' = [turn EXCEPT !.st = "done"]
    /\ fate' = [fate EXCEPT ![Cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p] = Idle(Cur)]
    /\ UNCHANGED <<lock, faults, answered, deaths, stranded, up, split>>

\* The tools finish and the turn's next request starts with a new module.
ToolsDone(p) ==
    /\ ps[p].pc = "tools"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, faults, fate, answered, deaths, stranded, up, split>>

\* A failure the module waits out, and the retry when the wait ends.
Fail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [ph |-> "waiting", clean |-> FALSE, need |-> "none"]]
    /\ ps' = [ps EXCEPT ![p].pc = "wait"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, fate, answered, deaths, stranded, up, split>>

Retry(p) ==
    /\ ps[p].pc = "wait"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, faults, fate, answered, deaths, stranded, up, split>>

\* A failure only the user can fix, such as an expired sign-in.
NeedFail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [ph |-> "need", clean |-> FALSE, need |-> "other"]]
    /\ ps' = [ps EXCEPT ![p].pc = "need", ![p].q = "other"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, fate, answered, deaths, stranded, up, split>>

-----------------------------------------------------------------------------
(* The world.                                                              *)

\* SIGKILL or a crash. Counts as an abrupt death of the turn when the turn
\* is open in the log and not yielded, or when work (a send or rerun) has
\* already started.
Kill(p) ==
    LET counts == (turn.st = "open" /\ ~turn.yield) \/ ps[p].pc \in {"flight", "late", "rerun"} IN
    /\ ps[p].pc # "off" /\ CanFault
    /\ deaths' = IF counts /\ ps[p].req > 0
                    THEN [deaths EXCEPT ![ps[p].req] = Min(@ + 1, CrashLoopAfter)]
                    ELSE deaths
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ up' = [up EXCEPT !.pending = FALSE, !.armed = FALSE]
    /\ UNCHANGED <<turn, fate, answered, stranded, split>>

\* SIGHUP, SIGTERM, or a terminal that hangs up. fx saves the running
\* module's record marked clean, or closes the open turn cleanly, and leaves
\* the turn resumable; it never ends the turn as cancelled. Today, and
\* planted defect no_closing, die as a kill does. A close is not a death:
\* `deaths` stays.
Close(p) ==
    LET saves == Proposed /\ Bug # "no_closing" /\ turn.st = "open" /\ ~ps[p].cont IN
    /\ ps[p].pc # "off" /\ CanFault
    /\ turn' = IF saves
                  THEN IF ModuleActive(p)
                          THEN [turn EXCEPT
                                  !.st = "closed",
                                  !.rec = IF ps[p].pc \in {"save", "late"}
                                             THEN [ph |-> "sending", clean |-> TRUE, need |-> "none"]
                                             ELSE [@ EXCEPT !.clean = TRUE]]
                          ELSE IF turn.rec.ph = "none"
                                  THEN [turn EXCEPT !.st = "closed"]
                                  ELSE turn
                  ELSE turn
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ up' = ExitUp
    /\ UNCHANGED <<fate, answered, deaths, stranded, split>>

-----------------------------------------------------------------------------
(* Ctrl+G.                                                                 *)

\* An upgrade is ready and the user presses Ctrl+G. fx refuses while the
\* request asks or waits for the user; otherwise the restart waits for the
\* running turn to stop (app_upgrade_runtime.zig). Under "today", fx
\* before its recovery records refused while a turn ran, so only the
\* proposed design has this step.
Upgrade(p) ==
    /\ Proposed /\ ~up.pending /\ Holds(p)
    /\ ps[p].pc \in {"idle", "save", "rerun", "flight", "late", "wait", "tools", "final"}
    /\ up' = [up EXCEPT !.pending = TRUE, !.armed = TRUE]
    /\ UNCHANGED <<turn, lock, ps, faults, fate, answered, deaths, stranded, split>>

\* The turn stops at its save before a model request once the turn is in
\* the log (quiesce.zig), and holds there while the restart waits
\* (orchestrator.zig yieldTurn, WorkerRuntime.holdForRestart). The save
\* records the module's state marked clean, as a close does, and marks the
\* turn yielded for the next launch to continue. Planted defect
\* yield_unclean: the record is saved as a death and not marked yielded.
\* Planted defect yield_first: the turn stops at its prompt's first send,
\* before it reaches the log.
Hold(p) ==
    LET saves == ~ps[p].cont IN
    /\ up.pending /\ Holds(p)
    /\ ps[p].pc = "save" /\ (saves \/ Bug = "yield_first")
    /\ turn' = IF saves
                  THEN [turn EXCEPT
                          !.rec = [ph |-> "sending", clean |-> (Bug # "yield_unclean"), need |-> "none"],
                          !.yield = (Bug # "yield_unclean")]
                  ELSE turn
    /\ ps' = [ps EXCEPT ![p].pc = "held"]
    /\ UNCHANGED <<lock, faults, fate, answered, deaths, stranded, up, split>>

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
    /\ UNCHANGED <<turn, fate, answered, deaths, stranded, split>>

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
    /\ UNCHANGED <<turn, lock, faults, fate, answered, deaths, stranded, split>>

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
    /\ turn' = Written(p, [ph |-> "sending", clean |-> FALSE, need |-> "none"])
    /\ faults' = faults + 1
    /\ IF Bug = "yield_unsaved"
          THEN /\ ps' = [ps EXCEPT ![p] = OffProc]
               /\ lock' = lock \ {p}
               /\ up' = [up EXCEPT !.pending = FALSE, !.armed = FALSE, !.yielded = ps[p].req]
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE]
               /\ UNCHANGED <<lock, up>>
    /\ UNCHANGED <<fate, answered, deaths, stranded, split>>

Init ==
    /\ turn = NoTurn /\ lock = {}
    /\ ps = [p \in Procs |-> OffProc]
    /\ faults = 0 /\ fate = [r \in Reqs |-> "none"]
    /\ answered = [r \in Reqs |-> FALSE]
    /\ deaths = [r \in Reqs |-> 0]
    /\ stranded = FALSE
    /\ up = NoUpgrade
    /\ split = FALSE

Next ==
    \E p \in Procs :
        \/ Launch(p) \/ Prompt(p) \/ UserContinue(p) \/ Enter(p) \/ Esc(p)
        \/ Quit(p) \/ Rerun(p) \/ RerunDone(p) \/ Save(p) \/ LateSave(p)
        \/ Respond(p) \/ Finish(p) \/ ToolsDone(p) \/ Fail(p) \/ Retry(p)
        \/ NeedFail(p) \/ Kill(p) \/ Close(p) \/ Upgrade(p) \/ Hold(p)
        \/ Relaunch(p) \/ CancelRestart(p) \/ YieldSaveFails(p)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* The request on the wire was sent again by a launch, with no user input.
AutoSend(p) == ps[p].auto /\ ps[p].pc \in {"save", "rerun", "flight", "late"}

\* A launch that finds a request a kill, a crash, or a close interrupted
\* sends it again on its own, unless the guard stopped it.
AutoResumes == ~stranded

\* A launch never moves a request to a question it was not already waiting on.
ResumeNeverAsks == \A p \in Procs : ps[p].pc = "ask" => ps[p].q = "other"

\* A close or a yield is never counted as a crash.
NoFalseCrash ==
    /\ \A p \in Procs : ps[p].pc # "off" /\ ps[p].req > 0 => ps[p].md <= deaths[ps[p].req]
    /\ turn.req > 0 => turn.crashes <= deaths[turn.req]

\* With the world's true count of abrupt deaths of a turn at CrashLoopAfter
\* or more, no process sends or reruns for that turn, and the turn ended
\* without a question.
CrashLoopStops ==
    \A r \in Reqs : deaths[r] >= CrashLoopAfter =>
        \A p \in Procs : ps[p].req = r =>
            /\ ps[p].pc \notin {"save", "rerun", "flight", "late"}
            /\ ps[p].q = "none"

\* A request whose final answer was saved is never sent again on its own.
DoneNeverResent == \A p \in Procs : AutoSend(p) => ~answered[ps[p].req]

\* A request the user cancelled or gave up is never sent again on its own.
CancelNeverResumes == \A p \in Procs : AutoSend(p) => fate[ps[p].req] # "cancel"

\* A resumed request continues the stopped turn: the log holds one turn for
\* the request, with the work the stopped turn had.
SameTurn == ~split

\* One session, one process working on its request.
Working(p) == ps[p].pc \in {"ask", "save", "rerun", "flight", "late", "wait",
                             "need", "tools", "final", "held"}
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
