---------------------------- MODULE ChildResume ----------------------------
(***************************************************************************)
(* How a subagent's work continues across a Ctrl+G restart. One parent and *)
(* one child run one task of N steps. A restart asked while the child runs *)
(* makes its turn yield at a step boundary after the first step: the turn  *)
(* writes the yield marker and holds. The restart's exit leaves the held   *)
(* turn open in the child's log and finishes the parent's open work        *)
(* cancelled, which owes a report. A later launch repairs what the exit or *)
(* a crash left open (the open's repair, D1: each open work becomes        *)
(* interrupted and owes a report), saves one continuation work for a       *)
(* yielded turn, and then delivers the owed reports that no later work     *)
(* replaces. The continuation work continues the yielded turn and runs the *)
(* rest of the task, so the parent gets one report, from its last work.    *)
(*                                                                         *)
(* The model mirrors the continuation contract the build follows: the exit *)
(* finishes the open work cancelled and leaves the held turn open in the   *)
(* child's log (contract step 1), each work saves the work it              *)
(* replaces (step 2), the open asks one question of the child's log        *)
(* (step 3), the open starts the continuation before it resumes the owed   *)
(* reports (step 4), the report fold skips a work that a later work        *)
(* replaces (step 5), the continuation resumes the held turn (step 6), and *)
(* a crash during the hold leaves the marker for the next open (step 8).   *)
(* The code that builds the contract today: the crash repair in            *)
(* src/core/session_manager/session.zig (repair, D1), the continuation in  *)
(* src/core/subagent/tool_host.zig (continueYieldedWorks and               *)
(* yieldedContinuationCandidate), its child-turn question in               *)
(* src/core/session/session_adapter.zig (Store.childTurnYielded), and      *)
(* src/core/subagent/reports.zig (pendingReports, the fold), the host      *)
(* in src/core/app/app_session_runtime.zig (enableSubagentHostV2), and     *)
(* the child's slot in src/core/app/app_agents_runtime.zig                 *)
(* (startInContext).                                                       *)
(*                                                                         *)
(* The child's log: its steps done, whether its newest turn ends in the    *)
(* yield marker, and whether a later turn continued that turn. The         *)
(* parent's log: a sequence of works. A work's id is its position, and its *)
(* replaces link names the work it continues (0 for none). A report is     *)
(* delivered at most once per work. Ghost counters record how often each   *)
(* step ran.                                                               *)
(*                                                                         *)
(* Processes: fx runs or is dead. Ctrl+G asks the restart; Yield, Release, *)
(* and Exit make the restart's exit; Crash kills fx at any time, and the   *)
(* open work stays open. Open is a new launch. Continue resumes the held   *)
(* turn from a continuation work. Step runs the child's next step, Finish  *)
(* completes the work after the last step, and Deliver hands an owed,      *)
(* untaken report to the parent.                                           *)
(*                                                                         *)
(* A crash after the continuation has started ends that work interrupted,  *)
(* which owes its report, as any crash in a subagent's work does. So the   *)
(* model checks TaskReported without crashes (childresume.cfg).            *)
(*                                                                         *)
(* Left out: a step is atomic (its model request and its tool), so retries *)
(* and a crash inside a step are Recovery.tla's and Resume.tla's; one      *)
(* child and one task; steering and mail; the parent's wait tool; nested   *)
(* children; ACP and fx ask subagents; the saved admission fields, which   *)
(* a continuation copies. A continuation owes its report by the same rule  *)
(* as any work. Bounds: MaxRestarts Ctrl+G presses and MaxCrashes crashes. *)
(* Bug plants one defect; each config names the rule that must catch it.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    N,            \* the steps in the task, such as 3
    MaxRestarts,  \* the Ctrl+G presses the run may take, such as 2
    MaxCrashes,   \* the crashes the run may take, such as 0 or 1
    Bug           \* "none", or the name of one planted defect

Bugs == {"none", "no_continuation", "no_replaces_link",
         "reports_before_continuation", "double_continuation"}

ASSUME /\ N \in Nat /\ N >= 2
       /\ MaxRestarts \in Nat /\ MaxCrashes \in Nat
       /\ Bug \in Bugs

\* The most works a run keeps: one for the task, and up to two for each
\* restart or crash, because a planted defect can save two at one open.
WorkCap == 1 + 2 * (MaxRestarts + MaxCrashes)

WorkStates == {"open", "completed", "cancelled", "interrupted"}

WorkRec == [state : WorkStates, replaces : 0..WorkCap, owes : BOOLEAN, taken : BOOLEAN]

VARIABLES
    proc,       \* TRUE: fx runs (the parent and the child's host)
    asked,      \* Ctrl+G asked the restart in this launch
    released,   \* the restart released the held turns
    restarts,   \* Ctrl+G presses so far
    crashes,    \* crashes so far
    steps,      \* the child's steps done
    ran,        \* ghost: how many times each step ran
    yielded,    \* the child's newest turn ends in the yield marker
    continued,  \* a later turn continued that turn
    works       \* the parent's log: a sequence of works

vars == <<proc, asked, released, restarts, crashes, steps, ran, yielded, continued, works>>

NewWork(link) == [state |-> "open", replaces |-> link, owes |-> FALSE, taken |-> FALSE]

Replaced(ws, i) == \E j \in 1..Len(ws) : ws[j].replaces = i

\* An owed, untaken report of a finished work that no later work replaces.
Eligible(ws, i) ==
    /\ ws[i].owes /\ ~ws[i].taken
    /\ ws[i].state # "open"
    /\ ~Replaced(ws, i)

Deliverable(ws) == {i \in 1..Len(ws) : Eligible(ws, i)}

DeliverAll(ws, S) ==
    [i \in 1..Len(ws) |-> IF i \in S THEN [ws[i] EXCEPT !.taken = TRUE] ELSE ws[i]]

\* The open's repair (D1): every open work becomes end, and owes its report.
EndOpen(ws, outcome) ==
    [i \in 1..Len(ws) |-> IF ws[i].state = "open"
                          THEN [ws[i] EXCEPT !.state = outcome, !.owes = TRUE]
                          ELSE ws[i]]

LastOpen == works[Len(works)].state = "open"

\* The child's turn is in a step, so the restart waits for it.
Busy == ~yielded /\ \E i \in 1..Len(works) : works[i].state = "open"

\* The open's question (contract step 3), about the last work: it ended
\* cancelled or interrupted, nothing replaces it, the child's log ends in
\* the marker, and no later turn continued it.
ContinuationOwed(ws) ==
    /\ ws[Len(ws)].state \in {"cancelled", "interrupted"}
    /\ ~Replaced(ws, Len(ws))
    /\ yielded /\ ~continued
    /\ Len(ws) < WorkCap

\* Planted defect double_continuation: the open saves a continuation for
\* every cancelled or interrupted work, with no check on the works after it.
RECURSIVE AddEach(_, _, _)
AddEach(acc, base, i) ==
    IF i > Len(base) THEN acc
    ELSE AddEach(IF (base[i].state \in {"cancelled", "interrupted"})
                    /\ yielded /\ (Len(acc) < WorkCap)
                 THEN Append(acc, NewWork(i))
                 ELSE acc,
                 base, i + 1)

TypeOK ==
    /\ proc \in BOOLEAN /\ asked \in BOOLEAN /\ released \in BOOLEAN
    /\ restarts \in 0..MaxRestarts /\ crashes \in 0..MaxCrashes
    /\ steps \in 0..N
    /\ ran \in [1..N -> Nat]
    /\ yielded \in BOOLEAN /\ continued \in BOOLEAN
    /\ Len(works) \in 1..WorkCap
    /\ \A i \in 1..Len(works) : works[i] \in WorkRec

Init ==
    /\ proc = TRUE /\ asked = FALSE /\ released = FALSE
    /\ restarts = 0 /\ crashes = 0
    /\ steps = 0 /\ ran = [k \in 1..N |-> 0]
    /\ yielded = FALSE /\ continued = FALSE
    /\ works = << NewWork(0) >>

-----------------------------------------------------------------------------
(* The restart.                                                            *)

\* Ctrl+G asks the restart while fx runs.
CtrlG ==
    /\ proc /\ ~asked /\ ~released /\ restarts < MaxRestarts
    /\ asked' = TRUE
    /\ restarts' = restarts + 1
    /\ UNCHANGED <<proc, released, crashes, steps, ran, yielded, continued, works>>

\* The child's turn reaches a step boundary after its first step, while the
\* restart is asked: it writes the marker and holds.
Yield ==
    /\ proc /\ asked /\ LastOpen /\ ~yielded
    /\ steps >= 1 /\ steps < N
    /\ yielded' = TRUE /\ continued' = FALSE
    /\ UNCHANGED <<proc, asked, released, restarts, crashes, steps, ran, works>>

\* Once nothing runs, the held turns are released.
Release ==
    /\ proc /\ asked /\ ~released /\ ~Busy
    /\ released' = TRUE
    /\ UNCHANGED <<proc, asked, restarts, crashes, steps, ran, yielded, continued, works>>

\* The restart's exit (contract step 1): the held turn stays open in the
\* child's log, and each open work finishes cancelled and owes a report.
Exit ==
    /\ proc /\ released
    /\ proc' = FALSE /\ asked' = FALSE /\ released' = FALSE
    /\ works' = EndOpen(works, "cancelled")
    /\ UNCHANGED <<restarts, crashes, steps, ran, yielded, continued>>

\* A crash at any time: the open work stays open.
Crash ==
    /\ proc /\ crashes < MaxCrashes
    /\ proc' = FALSE /\ asked' = FALSE /\ released' = FALSE
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<restarts, steps, ran, yielded, continued, works>>

-----------------------------------------------------------------------------
(* The launch.                                                             *)

\* The open (contract steps 3 and 4): the repair (D1) interrupts every open
\* work, then the continuation is saved before the owed reports are
\* delivered. Planted defect no_continuation: no continuation is saved.
\* Planted defect no_replaces_link: the continuation does not name the work
\* it replaces. Planted defect reports_before_continuation: the owed reports
\* go out before the continuation is saved. Planted defect
\* double_continuation: AddEach saves a continuation for every such work.
Open ==
    /\ ~proc
    /\ LET rep == EndOpen(works, "interrupted")
           link == IF Bug = "no_replaces_link" THEN 0 ELSE Len(rep)
           withCont ==
               IF Bug = "double_continuation"
               THEN AddEach(rep, rep, 1)
               ELSE IF Bug # "no_continuation" /\ ContinuationOwed(rep)
                    THEN Append(rep, NewWork(link))
                    ELSE rep
           due ==
               IF Bug = "reports_before_continuation"
               THEN Deliverable(rep)
               ELSE Deliverable(withCont)
       IN /\ proc' = TRUE
          /\ works' = DeliverAll(withCont, due)
    /\ UNCHANGED <<asked, released, restarts, crashes, steps, ran, yielded, continued>>

\* A continuation work resumes the held turn (contract step 6): the marker
\* clears, the turn is marked continued, and the child goes on. Continue
\* does not run while the restart is asked.
Continue ==
    /\ proc /\ ~asked /\ LastOpen
    /\ works[Len(works)].replaces # 0
    /\ yielded /\ ~continued
    /\ yielded' = FALSE /\ continued' = TRUE
    /\ UNCHANGED <<proc, asked, released, restarts, crashes, steps, ran, works>>

-----------------------------------------------------------------------------
(* The child's steps and the parent's reports.                             *)

\* The child runs its next step: a model request, then its tool. Once a
\* restart is asked, a step past the first waits for the yield.
Step ==
    /\ proc /\ LastOpen /\ ~yielded /\ steps < N
    /\ (~asked \/ steps = 0)
    /\ steps' = steps + 1
    /\ ran' = [ran EXCEPT ![steps + 1] = @ + 1]
    /\ UNCHANGED <<proc, asked, released, restarts, crashes, yielded, continued, works>>

\* After the last step, the open work finishes completed and owes a report.
Finish ==
    /\ proc /\ LastOpen /\ steps = N /\ ~yielded
    /\ works' = [works EXCEPT ![Len(works)].state = "completed",
                              ![Len(works)].owes = TRUE]
    /\ UNCHANGED <<proc, asked, released, restarts, crashes, steps, ran, yielded, continued>>

\* An owed, untaken report reaches the parent, once per work.
Deliver(i) ==
    /\ proc /\ i \in 1..Len(works) /\ Eligible(works, i)
    /\ works' = [works EXCEPT ![i].taken = TRUE]
    /\ UNCHANGED <<proc, asked, released, restarts, crashes, steps, ran, yielded, continued>>

\* Nothing else is left to do once a report has been delivered.
Done ==
    /\ \E i \in 1..Len(works) : works[i].taken
    /\ UNCHANGED vars

Next ==
    \/ CtrlG \/ Yield \/ Release \/ Exit \/ Crash \/ Open \/ Continue
    \/ Step \/ Finish \/ Done
    \/ \E i \in 1..WorkCap : Deliver(i)

\* fx's own steps happen; the person's Ctrl+G and a crash may not.
Fairness ==
    /\ WF_vars(Open) /\ WF_vars(Release) /\ WF_vars(Exit)
    /\ WF_vars(Yield) /\ WF_vars(Continue) /\ WF_vars(Step) /\ WF_vars(Finish)
    /\ \A i \in 1..WorkCap : WF_vars(Deliver(i))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* No step runs more than once.
StepsOnce == \A k \in 1..N : ran[k] <= 1

\* The steps run in order, and each one that is done ran once.
StepsInOrder == \A k \in 1..N : ran[k] = IF k <= steps THEN 1 ELSE 0

\* At most one report is delivered for the task, over all its works.
OneReport ==
    \A i, j \in 1..Len(works) : (works[i].taken /\ works[j].taken) => i = j

\* No delivered report belongs to a work that a later work replaces.
NoReplacedReport ==
    \A i \in 1..Len(works) : works[i].taken => ~Replaced(works, i)

\* At most one work replaces any given work.
OneContinuation ==
    \A i, j \in 1..Len(works) :
        (i # j /\ works[i].replaces # 0) => works[i].replaces # works[j].replaces

\* While fx runs, a yielded turn's work stays open, so a continuation can
\* still resume it. Planted defect no_continuation breaks this at the open.
YieldedTurnKeptOpen == (proc /\ yielded) => LastOpen

\* The task's report is delivered: a work that completed the task is
\* taken. Checked without crashes (MaxCrashes = 0): a crash that is not
\* during the hold ends the work interrupted, as today.
TaskReported ==
    <>(\E i \in 1..WorkCap : (i <= Len(works) /\ works[i].state = "completed" /\ works[i].taken))

=============================================================================
