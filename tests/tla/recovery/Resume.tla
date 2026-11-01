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
(* A process ends in one of three ways:                                    *)
(* - Quit: /quit or Ctrl+C twice. It cancels the request first, as Esc     *)
(*   does, so nothing resumes.                                             *)
(* - Close: SIGHUP or SIGTERM, from a closed window, a logout, or a        *)
(*   reboot. fx gives the module `closing`, saves the record it returns,   *)
(*   which is marked clean, and exits.                                     *)
(* - Kill: SIGKILL or a crash, at any moment.                              *)
(*                                                                         *)
(* Policy selects fx's behavior:                                           *)
(* - "today" saves no record, and a close dies as a kill does. A launch    *)
(*   shows the interrupted turn, and the request goes out again only when  *)
(*   the user sends a message such as "continue".                          *)
(* - "proposed" saves the module's record before every send and clears it  *)
(*   when the request's response arrives. A launch that finds a turn ended *)
(*   by a crash, with a request or tool work unfinished, continues it in a *)
(*   new turn. The module sends at once, or asks: after the request        *)
(*   crashed fx twice with a send in flight, when its record is more than  *)
(*   a day old, or when it was waiting for the user. A turn reaches the    *)
(*   log with its first send, in one write with that send's record; a turn *)
(*   that asks first is written when the question shows.                  *)
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
         "ignore_age", "no_lock"}

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
\* calls between requests; "ask" shows a question at launch.
PCs == {"off", "idle", "ask", "save", "flight", "late", "wait", "need",
        "tools", "final"}
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
    stranded   \* a launch left a request it could have resumed

vars == <<turn, lock, wall, ps, faults, fate, answered, seen, stranded>>

TypeOK ==
    /\ turn \in Turns /\ lock \subseteq Procs /\ wall \in Days
    /\ ps \in [Procs -> ProcStates]
    /\ faults \in 0..MaxFaults
    /\ fate \in [Reqs -> {"none", "open", "ok", "cancel"}]
    /\ answered \in [Reqs -> BOOLEAN]
    /\ seen \in 0..CrashLoopAfter
    /\ stranded \in BOOLEAN

-----------------------------------------------------------------------------
(* Derived values.                                                         *)

Today    == Policy = "today"
Proposed == Policy = "proposed"
CanFault == faults < MaxFaults
Holds(p) == p \in lock
Cur      == turn.req

\* The turn a save writes: a new one, or the newest with the record replaced.
Written(p, r) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "open", rec |-> r, work |-> "none", at |-> wall]
       ELSE [turn EXCEPT !.rec = r, !.at = wall]

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
        ask(q) == /\ turn' = [req |-> t.req, st |-> "open", work |-> "none", at |-> wall,
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
    /\ UNCHANGED <<wall, faults, fate, answered, seen>>

-----------------------------------------------------------------------------
(* The user.                                                               *)

\* A new message, written to the log with its first send. A request left
\* interrupted is given up.
Prompt(p) ==
    LET r == NextReq IN
    /\ ps[p].pc = "idle" /\ Holds(p) /\ r <= MaxReq
    /\ fate' = [fate EXCEPT ![r] = "open",
                            ![Cur] = IF Cur > 0 /\ @ = "open" THEN "cancel" ELSE @]
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = r, !.cont = TRUE]]
    /\ seen' = 0
    /\ UNCHANGED <<turn, lock, wall, faults, answered, stranded>>

\* "continue" after a launch that did not resume: a new turn for the same
\* request, sent because the user asked, even when its answer was saved.
UserContinue(p) ==
    /\ ps[p].pc = "idle" /\ Holds(p)
    /\ Cur > 0 /\ turn.st = "crash" /\ fate[Cur] = "open"
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = Cur,
                                               !.cont = TRUE, !.md = Count(turn.rec)]]
    /\ answered' = [answered EXCEPT ![Cur] = FALSE]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, seen, stranded>>

\* Enter at a question, or after fixing what a request waits on: send again.
\* Answering the crash-loop question starts the count over (recovery.zig
\* onUserContinue), once the send's save records it.
Enter(p) ==
    LET loop == ps[p].q = "crash" IN
    /\ ps[p].pc \in {"ask", "need"}
    /\ ps' = [ps EXCEPT ![p].pc = "save", ![p].q = "none", ![p].auto = FALSE,
                        ![p].md = IF loop THEN 0 ELSE @, ![p].fresh = loop]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>

\* The request ends as cancelled: its turn, written now if it was not yet.
Cancelled(p) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "cancel", rec |-> NoRec, work |-> "none", at |-> wall]
       ELSE [turn EXCEPT !.st = "cancel", !.rec = NoRec]

\* Esc: the request ends, and nothing resumes it.
Esc(p) ==
    /\ ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need"}
    /\ turn' = Cancelled(p)
    /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
    /\ ps' = [ps EXCEPT ![p] = Idle(ps[p].req)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded>>

\* /quit cancels a running request first, as Esc does; a turn whose answer
\* is saved commits.
Quit(p) ==
    LET pc == ps[p].pc IN
    /\ pc # "off"
    /\ CASE pc = "final" ->
              /\ turn' = [turn EXCEPT !.st = "done", !.rec = NoRec]
              /\ fate' = [fate EXCEPT ![Cur] = "ok"]
         [] pc \in {"ask", "save", "flight", "late", "wait", "need", "tools"} ->
              /\ turn' = Cancelled(p)
              /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
         [] OTHER -> UNCHANGED <<turn, fate>>
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ seen' = IF pc \in {"idle", "off"} THEN seen ELSE 0
    /\ UNCHANGED <<wall, faults, answered, stranded>>

-----------------------------------------------------------------------------
(* fx's own steps.                                                         *)

\* Save the record and send. Today saves nothing. Planted defect
\* send_before_save: the send goes out first.
Save(p) ==
    /\ ps[p].pc = "save" /\ Holds(p)
    /\ IF Bug = "send_before_save"
          THEN /\ ps' = [ps EXCEPT ![p].pc = "late"]
               /\ UNCHANGED turn
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
               /\ turn' = Written(p, IF Today THEN NoRec ELSE SendRec(p))
    /\ seen' = IF ps[p].fresh /\ Bug # "send_before_save" THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded>>

LateSave(p) ==
    /\ ps[p].pc = "late"
    /\ turn' = Written(p, SendRec(p))
    /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
    /\ seen' = IF ps[p].fresh THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded>>

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
    /\ UNCHANGED <<lock, wall, faults, fate, stranded>>

\* The turn with the final answer commits.
Finish(p) ==
    /\ ps[p].pc = "final"
    /\ turn' = [turn EXCEPT !.st = "done"]
    /\ fate' = [fate EXCEPT ![Cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p] = Idle(Cur)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded>>

\* The tools finish and the turn's next request starts with a new module.
ToolsDone(p) ==
    /\ ps[p].pc = "tools"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>

\* A failure the module waits out, and the retry when the wait ends.
Fail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "waiting"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "wait"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded>>

Retry(p) ==
    /\ ps[p].pc = "wait"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>

\* A failure only the user can fix, such as an expired sign-in.
NeedFail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "need",
                                                          !.need = "other"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "need", ![p].q = "other"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded>>

-----------------------------------------------------------------------------
(* The world.                                                              *)

\* SIGKILL or a crash. The open turn stays open.
Kill(p) ==
    /\ ps[p].pc # "off" /\ CanFault
    /\ seen' = IF OnWire(p) THEN Min(seen + 1, CrashLoopAfter) ELSE seen
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ UNCHANGED <<turn, wall, fate, answered, stranded>>

\* SIGHUP or SIGTERM. fx saves the running module's record marked clean in
\* its turn; with no request running, or none of its turn written yet,
\* nothing is saved. Today, and planted defect no_closing, die as a kill
\* does. A close is not a death: `seen` stays.
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
    /\ UNCHANGED <<wall, fate, answered, stranded>>

\* A day passes.
Day ==
    /\ wall = 0 /\ CanFault
    /\ wall' = 1
    /\ faults' = faults + 1
    /\ UNCHANGED <<turn, lock, ps, fate, answered, seen, stranded>>

Next ==
    \/ \E p \in Procs :
          \/ Launch(p) \/ Prompt(p) \/ UserContinue(p) \/ Enter(p) \/ Esc(p)
          \/ Quit(p) \/ Save(p) \/ LateSave(p) \/ Respond(p) \/ Finish(p)
          \/ ToolsDone(p) \/ Fail(p) \/ Retry(p) \/ NeedFail(p)
          \/ Kill(p) \/ Close(p)
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

\* One session, one process working on its request.
Working(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need",
                             "tools", "final"}
OneWorker == Cardinality({p \in Procs : Working(p)}) <= 1

=============================================================================
