--------------------- MODULE TuiParentApproval ---------------------------
(***************************************************************************)
(* A TUI subagent's approval request, and who answers it.                  *)
(*                                                                         *)
(* Design c is the code in this change: the prompt takes its copy of the   *)
(* review under the worker's mutex, while the request still waits, so the  *)
(* tool call that built it cannot free it first; a parent-routed request   *)
(* is never lent, and a note that cannot be posted refuses. Designs a, a2  *)
(* and b, and the trial of step 3b, are the designs not taken; their rows  *)
(* keep checking the traps they avoid.                                     *)
(*                                                                         *)
(* The person's spec: the request goes to main, which answers `approve` or *)
(* `deny` under its own permissions, as in Part 1 (PR #2198). It still     *)
(* shows on the subagent's own screen, so the person can answer there; a   *)
(* turn the person typed on that screen stays with the person; main's      *)
(* screen no longer borrows the request; the footer and the agent list stop *)
(* saying the subagent needs the person for it.                            *)
(*                                                                         *)
(* Design = "trial" is the reverted step 3b: the turn's prompter for a     *)
(* parent-started run (app_agent_runtime.zig:452, with `run.turn` set at   *)
(* :1652), the note, lending still on (app_agents_runtime.zig:1270-1274),  *)
(* and main's answer resolved and submitted in one step on main's thread    *)
(* (managed_owner.zig:1614-1634), which the loop learns of only at its next *)
(* sync. Design "a" keeps that ordering and stops lending a parent-routed   *)
(* request. Design "a2" is "a" with one guard: the worker frees the review  *)
(* memory only after no screen shows the request. Design "b" hands main's   *)
(* answer to the loop (`MainPost`), and the loop clears the prompt and any  *)
(* lent copy before it submits (`LoopApply`), all in one step.              *)
(*                                                                         *)
(* Two screens can hold a request: the child's own prompt (`shown`, synced  *)
(* from the worker by the loop) and the copy an instance lent (`lent`).     *)
(* Both carry the review pointer borrowed from the tool call, so `freed`    *)
(* models the call ending and letting it go. `NoStalePrompt` is the rule    *)
(* that no screen draws a prompt whose review memory is freed, and          *)
(* `NoStaleLent` the rule that no screen holds a request that stopped       *)
(* waiting (map M1.3a). `a` breaks the first and the trial the second.      *)
(*                                                                         *)
(* `Ask` is requestChildPermission and registerApproval                    *)
(* (src/core/subagent/execution.zig:495-537, :621-653): a run the parent   *)
(* started registers and waits on the child's own worker                  *)
(* (worker_runtime.zig:3274); a turn the person typed has no `turn`        *)
(* (app_agent_runtime.zig:1660-1676) and registers nothing. `PostNote` is  *)
(* noteChildApproval (tool_host.zig:2587-2610) and `MarkNoted` is          *)
(* markNoted (approval_registry.zig:373-378). `NoteFails` is a note that   *)
(* cannot be posted: Part 1 refuses the request at once                    *)
(* (execution.zig:578-586), and FailedNote = "person" leaves it with the   *)
(* person instead. `RegisterFailsFull` is registerTool at max_pending      *)
(* (approval_registry.zig:247, execution.zig:530-534).                     *)
(*                                                                         *)
(* `Lend` is lendPrompt and lendApproval (app_agents_runtime.zig:1197-     *)
(* 1218, :1270-1274), `ReturnLend` is returnApproval and keepLentApproval  *)
(* (app_agents_runtime.zig:1278-1307), and `PersonAnswerMain` is           *)
(* submitPermissionChoice on a lent copy, whose prompt clears in the same  *)
(* step (input_approval_runtime.zig:257-269). `PersonAnswerChild` is the   *)
(* same call on the child's own screen. `MainAnswer` is answerApproval     *)
(* (tool_host.zig:2175-2291): approve runs the exact call through main's   *)
(* own check (tool_runtime.zig:2937-2974), which allows or refuses.        *)
(* `Stop` is stopChild and closeNamed (tool_host.zig:404-408,              *)
(* managed_owner.zig:795); `ChildTurnEnds` is the child's turn ending, its *)
(* request and review memory freed (worker_runtime.zig:978-995).           *)
(*                                                                         *)
(* The TUI has no fallback as fx ask has: the person can always answer on  *)
(* the child's own screen, and a lend goes back before that screen shows   *)
(* anything, so every request ends answered, stopped, or with its turn.    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Kids,         \* one or two subagents whose tool calls need approval
  Design,       \* "trial" | "a" | "b"
  FailedNote,   \* "refuse" | "person": what a note that cannot post does
  RegistryFull, \* whether the registry already holds max_pending requests
  Mutant        \* "none", or one defect planted in the design

ASSUME Design \in {"trial", "a", "a2", "b", "c"}
ASSUME FailedNote \in {"refuse", "person"}
ASSUME RegistryFull \in BOOLEAN
ASSUME Mutant \in {"none", "lend_routed", "no_withdraw", "note_typed",
                   "free_anyway", "b_note_keeps_prompt"}

VARIABLES
  kid,        \* each: "working", "waiting", "ran", "refused", "stopped", "cancelled"
  req,        \* the registry binding: "none", "registered", "noted"
  decision,   \* what the child's worker took: "none", "allow", "deny"
  answers,    \* answers that reached each worker: 0, 1, or 2
  shown,      \* the child's own prompt: "none" or "prompt"
  freed,      \* whether the tool call freed the review memory its prompt borrowed
  queued,     \* design b: main's answer waiting in the loop: "none", "allow", "deny"
  policy,     \* main's own check for each call: "allow" or "refuse"
  typed,      \* kids whose turn the person typed on their own screen
  mail,       \* notes posted and not yet taken by main
  posted,     \* notes posted whose request is not yet marked noted
  seen,       \* notes main's turns took
  main,       \* "idle" or "turn"
  lent,       \* the kid whose request main's screen holds a copy of, or "none"
  authorized, \* kids whose action main's check or the person allowed
  noPending,  \* kids a later answer told it no longer waits
  lost        \* kids whose main answer found no live request

vars == <<kid, req, decision, answers, shown, freed, queued, policy, typed, mail,
          posted, seen, main, lent, authorized, noPending, lost>>

\* A request the registry holds, which main's answer can find. It outlives the
\* run it belongs to unless an answer or the person took it away.
Requested(k) == req[k] \in {"registered", "noted"}

\* The child's worker still waits for a decision on its request.
WaitingOnWorker(k) == kid[k] = "waiting" /\ decision[k] = "none"

\* What the child's own prompt shows: the request while its worker waits, and
\* nothing while the lend holds it or the worker has its answer. `syncState`
\* (app_worker_runtime.zig:809-830) sets it from the worker every pass.
ShownFromWorker(k) ==
  IF WaitingOnWorker(k) /\ lent # k THEN "prompt" ELSE "none"

\* Whether a child registers its request: a parent-started run does, a turn the
\* person typed does not. `note_typed` plants the defect of registering one.
RegistersChild(k) == k \notin typed \/ Mutant = "note_typed"

\* Whether a person's answer takes the binding away. Design b does it in the
\* loop's own step; a and a2 do it a step later, and main's thread may resolve
\* in between. The trial did not, and `no_withdraw` plants that.
Withdraws == Design \in {"a", "a2", "b", "c"} /\ Mutant # "no_withdraw"

\* Whether a waiting request may be lent to an instance's screen. The trial lent
\* any waiting request; a, a2 and b lend only a turn the person typed, and
\* `lend_routed` plants the defect of lending a parent-routed one.
Lendable(k) == Design = "trial" \/ Mutant = "lend_routed" \/ k \in typed

\* Whether the worker may free the review memory before the loop has synced the
\* prompt. The trial and a free it as soon as the call goes on; a2 and b wait
\* until no screen shows the request. `free_anyway` plants the missing guard.
FreesWhenDone(k) ==
  \* c is the shipped design: the prompt owns a copy of its review, so the
  \* worker frees the call's memory whenever the call ends.
  \/ Design \in {"trial", "a", "c"} \/ Mutant = "free_anyway"
  \/ /\ shown[k] = "none"
     /\ lent # k

TypeOK ==
  /\ kid \in [Kids -> {"working", "waiting", "ran", "refused", "stopped",
                       "cancelled"}]
  /\ req \in [Kids -> {"none", "registered", "noted"}]
  /\ decision \in [Kids -> {"none", "allow", "deny"}]
  /\ answers \in [Kids -> 0..2]
  /\ shown \in [Kids -> {"none", "prompt"}]
  /\ freed \in [Kids -> BOOLEAN]
  /\ queued \in [Kids -> {"none", "allow", "deny"}]
  /\ policy \in [Kids -> {"allow", "refuse"}]
  /\ typed \subseteq Kids
  /\ mail \subseteq Kids
  /\ posted \subseteq Kids
  /\ seen \subseteq Kids
  /\ main \in {"idle", "turn"}
  /\ lent \in Kids \cup {"none"}
  /\ authorized \subseteq Kids
  /\ noPending \subseteq Kids
  /\ lost \subseteq Kids

Init ==
  /\ kid = [k \in Kids |-> "working"]
  /\ req = [k \in Kids |-> "none"]
  /\ decision = [k \in Kids |-> "none"]
  /\ answers = [k \in Kids |-> 0]
  /\ shown = [k \in Kids |-> "none"]
  /\ freed = [k \in Kids |-> FALSE]
  /\ queued = [k \in Kids |-> "none"]
  /\ policy \in [Kids -> {"allow", "refuse"}]
  /\ typed \in SUBSET Kids
  /\ mail = {}
  /\ posted = {}
  /\ seen = {}
  /\ main = "idle"
  /\ lent = "none"
  /\ authorized = {}
  /\ noPending = {}
  /\ lost = {}

\* `requestChildPermission` and `registerApproval`: the subagent's call needs
\* approval. A run the parent started registers the exact call, and the request
\* waits on the child's own worker. A turn the person typed registers nothing,
\* so the request stays on the child's own screen.
Ask(k) ==
  /\ kid[k] = "working"
  /\ req[k] = "none"
  /\ answers[k] = 0
  /\ \/ ~RegistersChild(k)
     \/ ~RegistryFull
  /\ kid' = [kid EXCEPT ![k] = "waiting"]
  /\ IF RegistersChild(k)
       THEN req' = [req EXCEPT ![k] = "registered"]
       ELSE req' = req
  /\ UNCHANGED <<decision, answers, shown, freed, queued, policy, typed, mail,
                 posted, seen, main, lent, authorized, noPending, lost>>

\* `registerTool` refuses at max_pending, so `requestChildPermission` answers
\* the child with a deny and the reason: the action does not run.
RegisterFailsFull(k) ==
  /\ RegistryFull
  /\ RegistersChild(k)
  /\ kid[k] = "working"
  /\ req[k] = "none"
  /\ kid' = [kid EXCEPT ![k] = "refused"]
  /\ UNCHANGED <<req, decision, answers, shown, freed, queued, policy, typed,
                 mail, posted, seen, main, lent, authorized, noPending, lost>>

\* `noteChildApproval`: one note to main, posted only after the request is
\* registered and while it still waits. A note for a request that already
\* ended is not posted.
PostNote(k) ==
  /\ WaitingOnWorker(k)
  /\ req[k] = "registered"
  /\ k \notin posted
  /\ posted' = posted \cup {k}
  /\ mail' = mail \cup {k}
  /\ UNCHANGED <<kid, req, decision, answers, shown, freed, queued, policy, typed,
                 seen, main, lent, authorized, noPending, lost>>

\* `markNoted`: the note went out, so the binding counts as noted. It is marked
\* only while the request still waits, and a mark for a request that ended does
\* nothing.
MarkNoted(k) ==
  /\ WaitingOnWorker(k)
  /\ req[k] = "registered"
  /\ k \in posted
  /\ req' = [req EXCEPT ![k] = "noted"]
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<kid, decision, answers, shown, freed, queued, policy, typed,
                 mail, seen, main, lent, authorized, noPending, lost>>

\* A note that cannot be posted. Part 1's rule refuses the request at once
\* (execution.zig:530-534): the worker takes a deny, and the loop clears the
\* prompt with it, except in the trial and in a, which apply it off the loop and
\* leave the prompt for their next sync. FailedNote = "person" takes the binding
\* away and leaves the request waiting, where the person answers it.
NoteFails(k) ==
  /\ WaitingOnWorker(k)
  /\ req[k] = "registered"
  /\ k \notin posted
  /\ IF FailedNote = "refuse"
       THEN /\ req' = [req EXCEPT ![k] = "none"]
            /\ posted' = posted
            /\ decision' = [decision EXCEPT ![k] = "deny"]
            /\ answers' = [answers EXCEPT ![k] = 1]
            /\ IF Design = "b" /\ Mutant # "b_note_keeps_prompt"
                 THEN /\ shown' = [shown EXCEPT ![k] = "none"]
                      /\ lent' = IF lent = k THEN "none" ELSE lent
                 ELSE /\ shown' = shown
                      /\ lent' = lent
       ELSE /\ req' = [req EXCEPT ![k] = "none"]
            /\ posted' = posted \ {k}
            /\ UNCHANGED <<decision, answers, shown, lent>>
  /\ UNCHANGED <<kid, freed, queued, policy, typed, mail, seen, main, authorized,
                 noPending, lost>>

\* `lendPrompt` and `lendApproval`: the instance on screen borrows the child's
\* prompt, which swaps it away from the child's own screen
\* (app_agents_runtime.zig:1270-1274). The trial lent any waiting request; a,
\* a2 and b lend only a turn the person typed.
Lend(k) ==
  /\ lent = "none"
  /\ shown[k] = "prompt"
  /\ WaitingOnWorker(k)
  /\ Lendable(k)
  /\ lent' = k
  /\ shown' = [shown EXCEPT ![k] = "none"]
  /\ UNCHANGED <<kid, req, decision, answers, freed, queued, policy, typed,
                 mail, posted, seen, main, authorized, noPending, lost>>

\* `returnApproval` and `keepLentApproval` (app_agents_runtime.zig:1278-1307):
\* the copy goes back when its subagent stops waiting, or when the person opens
\* that subagent, and the child's prompt shows what its worker still waits on.
ReturnLend ==
  /\ lent # "none"
  /\ lent' = "none"
  /\ shown' = [k \in Kids |-> IF lent = k THEN ShownFromWorker(k) ELSE shown[k]]
  /\ UNCHANGED <<kid, req, decision, answers, freed, queued, policy, typed,
                 mail, posted, seen, main, authorized, noPending, lost>>

\* `syncState` (app_worker_runtime.zig:809-830): the loop reads the child's
\* worker and shows or clears the child's own prompt. It runs a pass behind
\* main's answer in the trial and in a, which is what those designs leave open.
Sync(k) ==
  /\ shown[k] # ShownFromWorker(k)
  /\ shown' = [shown EXCEPT ![k] = ShownFromWorker(k)]
  /\ UNCHANGED <<kid, req, decision, answers, freed, queued, policy, typed,
                 mail, posted, seen, main, lent, authorized, noPending, lost>>

\* Main takes the notes waiting as mail in its turn (postAgentMessage,
\* src/main.zig:2156).
TakeMail ==
  /\ main = "idle"
  /\ mail # {}
  /\ main' = "turn"
  /\ seen' = seen \cup mail
  /\ mail' = {}
  /\ UNCHANGED <<kid, req, decision, answers, shown, freed, queued, policy,
                 typed, posted, lent, authorized, noPending, lost>>

\* `answerApproval` on main's thread: approve runs the subagent's exact call
\* through main's own check (tool_runtime.zig:2937-2974), which allows or
\* refuses; deny refuses without a check. The registry resolves the binding and
\* the worker takes the decision in one step, and the loop learns of it only at
\* its next `Sync`. An answer whose binding outlived its request is told it no
\* longer waits, and an answer that finds no binding while the child waits is
\* lost.
MainAnswer(k, d) ==
  /\ Design # "b"
  /\ main = "turn"
  /\ k \in seen
  /\ \/ /\ Requested(k)
        /\ WaitingOnWorker(k)
        /\ IF d = "deny" \/ policy[k] = "refuse"
             THEN /\ decision' = [decision EXCEPT ![k] = "deny"]
                  /\ authorized' = authorized
             ELSE /\ decision' = [decision EXCEPT ![k] = "allow"]
                  /\ authorized' = authorized \cup {k}
        /\ req' = [req EXCEPT ![k] = "none"]
        /\ answers' = [answers EXCEPT ![k] = 1]
        /\ noPending' = noPending
        /\ lost' = lost
     \/ /\ Requested(k)
        /\ ~WaitingOnWorker(k)
        /\ req' = [req EXCEPT ![k] = "none"]
        /\ decision' = decision
        /\ answers' = answers
        /\ noPending' = noPending \cup {k}
        /\ authorized' = authorized
        /\ lost' = lost
     \/ /\ req[k] = "none"
        /\ WaitingOnWorker(k)
        /\ lost' = lost \cup {k}
        /\ UNCHANGED <<req, decision, answers, authorized, noPending>>
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<kid, shown, freed, queued, policy, typed, mail, seen, main,
                 lent>>

\* Design b: main's answer is handed to the loop, which is the one writer of
\* every prompt. Nothing changes for the child's worker here.
MainPost(k, d) ==
  /\ Design = "b"
  /\ main = "turn"
  /\ k \in seen
  /\ Requested(k)
  /\ kid[k] = "waiting"
  /\ queued[k] = "none"
  /\ queued' = [queued EXCEPT ![k] = d]
  /\ UNCHANGED <<kid, req, decision, answers, shown, freed, policy, typed, mail,
                 posted, seen, main, lent, authorized, noPending, lost>>

\* Design b: the loop takes that answer and clears the child's prompt and any
\* lent copy in the same step as the submit, so no screen is left showing a
\* request whose memory is freed. A request that already took an answer is told
\* it no longer waits.
LoopApply(k) ==
  /\ Design = "b"
  /\ queued[k] # "none"
  /\ queued' = [queued EXCEPT ![k] = "none"]
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ IF WaitingOnWorker(k)
       THEN /\ decision' = [decision EXCEPT ![k] = queued[k]]
            /\ answers' = [answers EXCEPT ![k] = 1]
            /\ authorized' = IF queued[k] = "allow"
                                THEN authorized \cup {k} ELSE authorized
            /\ noPending' = noPending
       ELSE /\ decision' = decision
            /\ answers' = answers
            /\ authorized' = authorized
            /\ noPending' = noPending \cup {k}
  /\ shown' = [shown EXCEPT ![k] = "none"]
  /\ lent' = IF lent = k THEN "none" ELSE lent
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<kid, freed, policy, typed, mail, seen, main, lost>>

\* The person's answer in a and a2 takes the binding away a step later, so
\* main's thread may resolve it in between. In b the person's own step does it.
Withdraw(k) ==
  /\ Withdraws
  /\ Design # "b"
  /\ Requested(k)
  /\ decision[k] # "none"
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<kid, decision, answers, shown, freed, queued, policy, typed,
                 mail, seen, main, lent, authorized, noPending, lost>>

\* `submitPermissionChoice` on the child's own screen: the loop clears that
\* prompt and the answer reaches the child's worker in one step, as
\* input_approval_runtime.zig:259-274 does. Design b also takes the binding
\* away here; a and a2 do it in `Withdraw`, a step later.
PersonAnswerChild(k, d) ==
  /\ lent = "none"
  /\ shown[k] = "prompt"
  /\ WaitingOnWorker(k)
  /\ shown' = [shown EXCEPT ![k] = "none"]
  /\ decision' = [decision EXCEPT ![k] = d]
  /\ answers' = [answers EXCEPT ![k] = 1]
  /\ authorized' = IF d = "allow" THEN authorized \cup {k} ELSE authorized
  /\ IF Withdraws /\ Design = "b"
       THEN /\ req' = [req EXCEPT ![k] = "none"]
            /\ posted' = posted \ {k}
       ELSE /\ req' = req
            /\ posted' = posted
  /\ UNCHANGED <<kid, freed, queued, policy, typed, mail, seen, main, lent,
                 noPending, lost>>

\* The person answers the copy lent to main's screen: the loop clears the copy
\* and the child's prompt and submits in one step, which is why this path never
\* left a stale copy behind (input_approval_runtime.zig:257-274).
PersonAnswerMain(k, d) ==
  /\ lent = k
  /\ WaitingOnWorker(k)
  /\ lent' = "none"
  /\ shown' = [shown EXCEPT ![k] = "none"]
  /\ decision' = [decision EXCEPT ![k] = d]
  /\ answers' = [answers EXCEPT ![k] = 1]
  /\ authorized' = IF d = "allow" THEN authorized \cup {k} ELSE authorized
  /\ IF Withdraws /\ Design = "b"
       THEN /\ req' = [req EXCEPT ![k] = "none"]
            /\ posted' = posted \ {k}
       ELSE /\ req' = req
            /\ posted' = posted
  /\ UNCHANGED <<kid, freed, queued, policy, typed, mail, seen, main, noPending,
                 lost>>

\* The child's worker resumes: an allowed action runs, a denied one does not.
Resume(k) ==
  /\ kid[k] = "waiting"
  /\ decision[k] # "none"
  /\ kid' = [kid EXCEPT ![k] = IF decision[k] = "allow" THEN "ran" ELSE "refused"]
  /\ decision' = [decision EXCEPT ![k] = "none"]
  /\ UNCHANGED <<req, answers, shown, freed, queued, policy, typed, mail,
                 posted, seen, main, lent, authorized, noPending, lost>>

\* The tool call goes on and lets go of the review memory its prompt borrowed
\* (tool_admission.zig:1967-1980, approval_prompt.zig:53). The trial and a free
\* it as soon as the call has its answer, whether or not a screen still shows
\* the request; a2 and b wait until no screen does.
Free(k) ==
  /\ decision[k] # "none"
  /\ ~freed[k]
  /\ FreesWhenDone(k)
  /\ freed' = [freed EXCEPT ![k] = TRUE]
  /\ UNCHANGED <<kid, req, decision, answers, shown, queued, policy, typed, mail,
                 posted, seen, main, lent, authorized, noPending, lost>>

\* `stopChild` and `closeNamed` end a waiting child and drop its request
\* (tool_host.zig:404-408, managed_owner.zig:795); the lend goes back first
\* (app_agents_runtime.zig:2254), and an answer still queued has nowhere to go.
Stop(k) ==
  /\ main = "turn"
  /\ kid[k] = "waiting"
  /\ kid' = [kid EXCEPT ![k] = "stopped"]
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ mail' = mail \ {k}
  /\ posted' = posted \ {k}
  /\ lent' = IF lent = k THEN "none" ELSE lent
  /\ queued' = [queued EXCEPT ![k] = "none"]
  /\ noPending' = IF queued[k] = "none" THEN noPending ELSE noPending \cup {k}
  /\ UNCHANGED <<decision, answers, shown, freed, policy, typed, seen, main,
                 authorized, lost>>

\* The child's turn ends or is cancelled (RULES.md R2.4): its request is
\* withdrawn and its review memory freed (worker_runtime.zig:978-995).
ChildTurnEnds(k) ==
  /\ kid[k] = "waiting"
  /\ kid' = [kid EXCEPT ![k] = "cancelled"]
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ mail' = mail \ {k}
  /\ posted' = posted \ {k}
  /\ lent' = IF lent = k THEN "none" ELSE lent
  /\ queued' = [queued EXCEPT ![k] = "none"]
  /\ noPending' = IF queued[k] = "none" THEN noPending ELSE noPending \cup {k}
  /\ UNCHANGED <<decision, answers, shown, freed, policy, typed, seen, main,
                 authorized, lost>>

\* Main ends its turn.
EndTurn ==
  /\ main = "turn"
  /\ main' = "idle"
  /\ UNCHANGED <<kid, req, decision, answers, shown, freed, queued, policy, typed,
                 mail, posted, seen, lent, authorized, noPending, lost>>

\* Every subagent is settled and main has no mail: the behavior is over.
Finished ==
  /\ main = "idle"
  /\ mail = {}
  /\ \A k \in Kids : kid[k] \in {"ran", "refused", "stopped", "cancelled"}
  /\ UNCHANGED vars

Next ==
  \/ \E k \in Kids :
       Ask(k) \/ RegisterFailsFull(k) \/ PostNote(k) \/ MarkNoted(k)
       \/ NoteFails(k) \/ Resume(k) \/ Free(k) \/ Stop(k) \/ ChildTurnEnds(k)
       \/ Lend(k) \/ ReturnLend \/ Sync(k) \/ LoopApply(k) \/ Withdraw(k)
  \/ \E k \in Kids, d \in {"allow", "deny"} :
       MainAnswer(k, d) \/ MainPost(k, d) \/ PersonAnswerChild(k, d)
       \/ PersonAnswerMain(k, d)
  \/ TakeMail
  \/ EndTurn
  \/ Finished

Spec == Init /\ [][Next]_vars

\* Main's screen never holds a copy of a request that is no longer waiting. The
\* trial breaks this as soon as main answers a lent request, because the copy
\* stayed in main's prompt until the child's next sync gave it back (map M1.3a).
NoStaleLent == \A k \in Kids : lent = k => WaitingOnWorker(k)

\* No screen draws a prompt whose review memory is freed. Both copies of a
\* request borrow that memory from the child's tool call, so a free while either
\* still shows the request is a use-after-free (map M1.3a).
\* Under c a shown prompt reads its own copy, so freeing the call's memory
\* never makes it stale.
NoStalePrompt == \A k \in Kids : (shown[k] = "prompt" \/ lent = k) => (~freed[k] \/ Design = "c")

\* At most one answer reaches a request's worker. A later answer is told the
\* request no longer waits (`noPending`) and is never applied.
AnswerOnce == \A k \in Kids : answers[k] <= 1

\* A request whose turn the person typed is never noted to main, and so never
\* answered by main.
TypedStaysWithPerson ==
  \A k \in typed : k \notin posted /\ k \notin mail /\ k \notin seen

\* An action runs only when main's own check allowed it, or the person allowed
\* it (RULES.md R4.3, with the person added).
Authority == \A k \in Kids : kid[k] = "ran" => k \in authorized

\* Main's answer always finds the request its note named, while that request
\* still waits.
NoLostApprove == lost = {}

\* In designs a and b main's screen never shows a parent-routed request: only a
\* turn the person typed may be lent. The trial lent any waiting request.
NoPersonPromptForParentRouted ==
  Design = "trial" \/ (\A k \in Kids : lent = k => k \in typed)

=============================================================================
