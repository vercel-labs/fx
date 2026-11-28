------------------------------ MODULE AskWait ------------------------------
(***************************************************************************)
(* `fx tool ask`, sent by a bash program through the tool bridge. This is  *)
(* the design for slice 8, built in src/core/tool_bridge/bridge.zig (the   *)
(* prompt lock) and src/core/tooling/tool_runtime.zig (runBridgeAsk and    *)
(* QuestionWatch). tests/tla/drivers/tool_bridge/ walks every distinct     *)
(* step on the real code, checks recorded traces against TraceAskWait.tla, *)
(* and catches both planted bugs in ask-mutations.json.                    *)
(*                                                                         *)
(* A question opens in the session's one question slot                     *)
(* (`worker_runtime.zig` `requestQuestionBatchAnswerBlockingWithSource`,   *)
(* which asserts that the slot is free). So a bridged question takes the   *)
(* bridge's prompt lock and holds it until the question ends: permission   *)
(* prompts and questions show one at a time, and a second `ask` from the   *)
(* same program waits in line. A request that waits for the lock waits     *)
(* without a cancel, as a permission check does (`lockUncancelable`): once *)
(* it gets the lock, it gives up if its program is gone. The model has one *)
(* program; a request of another program, such as a subagent's, also waits *)
(* for this program's open question, as permission requests already do.    *)
(*                                                                         *)
(* The program can exit or be killed at any step; its socket then closes.  *)
(* A question whose program is gone is withdrawn at once, by a watch on    *)
(* the request's cancel flag that calls `cancelPendingQuestionBatch`, the  *)
(* call that already ends an MCP elicitation at its deadline. Its answer   *)
(* would reach no one. A permission prompt keeps the bridge's recorded     *)
(* rule (it stays until answered, and its answer runs nothing); ToolEdit   *)
(* models that.                                                            *)
(*                                                                         *)
(* Esc on a question cancels the turn, so fx stops the program. A host     *)
(* with no question UI (`fx ask`, ACP) refuses at once. After the first    *)
(* bash call yields, the bridge is gone, and a request is refused at once. *)
(* The bash call returns only after the bridge's requests have ended.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Reqs,         \* the program's `fx tool ask` clients, such as {1, 2}
    MaxPrograms,  \* how many programs the model may run
    Mutation      \* "none", or one planted defect that check.sh names

VARIABLES
    prog,      \* the last program: "none", "running", or "gone"
    programs,  \* programs started so far
    ui,        \* the host can show a question (the TUI); FALSE for fx ask and ACP
    bash,      \* the model's bash call: "idle", "first", or "yielded"
    req,       \* each client's request: "none", "queued", "shown", or "done"
    lock,      \* the bridge's prompt lock: 0, or the request that holds it
    slot,      \* the session's question slot: 0, or the request it shows
    crashed,   \* a question was put into a full slot, so the assert fired
    asked,     \* questions that the last program showed
    told       \* what each request told its client

vars == <<prog, programs, ui, bash, req, lock, slot, crashed, asked, told>>

NoReq == 0

Init ==
    /\ prog = "none"
    /\ programs = 0
    /\ ui \in BOOLEAN
    /\ bash = "idle"
    /\ req = [r \in Reqs |-> "none"]
    /\ lock = NoReq
    /\ slot = NoReq
    /\ crashed = FALSE
    /\ asked = 0
    /\ told = [r \in Reqs |-> "none"]

Inside == bash \in {"first", "yielded"}

Open(r) == req[r] \in {"queued", "shown"}

NoneOpen == \A r \in Reqs : ~Open(r)

\* Ends request r with what it tells its client, and frees what it held.
End(r, what) ==
    /\ req' = [req EXCEPT ![r] = "done"]
    /\ told' = [told EXCEPT ![r] = what]
    /\ lock' = IF lock = r THEN NoReq ELSE lock
    /\ slot' = IF slot = r THEN NoReq ELSE slot

\* The model calls bash with a new program. The bridge's requests for the
\* last program must have ended first, because the call tears that bridge down.
Run ==
    /\ bash = "idle"
    /\ prog # "running"
    /\ programs < MaxPrograms
    /\ prog' = "running"
    /\ programs' = programs + 1
    /\ bash' = "first"
    /\ req' = [r \in Reqs |-> "none"]
    /\ told' = [r \in Reqs |-> "none"]
    /\ asked' = 0
    /\ UNCHANGED <<ui, lock, slot, crashed>>

\* The yield time passes. A bridge request that is open holds the first call
\* (`managed_execution.zig` `yield_hold`). After the yield the bridge is gone.
Yield ==
    /\ bash = "first"
    /\ prog = "running"
    /\ NoneOpen
    /\ bash' = "yielded"
    /\ UNCHANGED <<prog, programs, ui, req, lock, slot, crashed, asked, told>>

\* The program ended, and the bridge's requests have ended, so the call returns.
Return ==
    /\ Inside
    /\ prog = "gone"
    /\ NoneOpen
    /\ bash' = "idle"
    /\ UNCHANGED <<prog, programs, ui, req, lock, slot, crashed, asked, told>>

\* The program exits, or it is killed, and its sockets close.
Gone ==
    /\ prog = "running"
    /\ prog' = "gone"
    /\ UNCHANGED <<programs, ui, bash, req, lock, slot, crashed, asked, told>>

\* The lock is free for a request when no question holds it. The planted bug
\* admission-lock-only holds the lock only for the permission check, as the
\* bridge did before slice 8, so a question never waits for it.
LockFree == lock = NoReq \/ Mutation = "admission-lock-only"

\* Request r takes the lock and shows its question in the session's question
\* slot. A full slot fires the assert.
ShowNow(r) ==
    /\ lock' = IF Mutation = "admission-lock-only" THEN lock ELSE r
    /\ IF slot = NoReq
       THEN slot' = r /\ crashed' = crashed
       ELSE slot' = slot /\ crashed' = TRUE
    /\ req' = [req EXCEPT ![r] = "shown"]
    /\ asked' = asked + 1

\* Client r sends `fx tool ask`. After the first call yielded, no bridge is
\* there (exit 3). A host with no question UI refuses at once (exit 6). With
\* the lock free, the request takes it and its question opens in this step:
\* the bridge takes the lock right after it admits the request, with nothing
\* between (`bridge.zig` `serve`). Else the request waits for the lock.
Send(r) ==
    /\ prog = "running"
    /\ req[r] = "none"
    /\ \/ /\ bash # "first"
          /\ End(r, "unavailable")
          /\ UNCHANGED <<crashed, asked>>
       \/ /\ bash = "first" /\ ~ui
          /\ End(r, "no-ui")
          /\ UNCHANGED <<crashed, asked>>
       \/ /\ bash = "first" /\ ui /\ LockFree
          /\ ShowNow(r)
          /\ UNCHANGED told
       \/ /\ bash = "first" /\ ui /\ ~LockFree
          /\ req' = [req EXCEPT ![r] = "queued"]
          /\ UNCHANGED <<told, lock, slot, crashed, asked>>
    /\ UNCHANGED <<prog, programs, ui, bash>>

\* A queued request takes the lock once it is free, and its question opens.
Show(r) ==
    /\ req[r] = "queued"
    /\ prog = "running"
    /\ LockFree
    /\ ShowNow(r)
    /\ UNCHANGED <<prog, programs, ui, bash, told>>

\* A queued request whose program is gone gives up without a prompt. Its wait
\* for the lock has no cancel, so it gives up only once the lock is free.
GiveUp(r) ==
    /\ req[r] = "queued"
    /\ prog = "gone"
    /\ lock = NoReq
    /\ End(r, "gave-up")
    /\ UNCHANGED <<prog, programs, ui, bash, crashed, asked>>

\* The person answers a question on screen. The answer reaches the client if
\* its program still runs; else it reaches no one, and nothing runs.
Answer(r) ==
    /\ req[r] = "shown"
    /\ End(r, "answer")
    /\ UNCHANGED <<prog, programs, ui, bash, crashed, asked>>

\* The person presses Esc on a question. That cancels the turn, so fx stops
\* the program.
Esc(r) ==
    /\ req[r] = "shown"
    /\ End(r, "esc")
    /\ prog' = IF prog = "running" THEN "gone" ELSE prog
    /\ UNCHANGED <<programs, ui, bash, crashed, asked>>

\* The watch sees that the request's program is gone and withdraws its
\* question. The planted bug watch-off removes the watch, so the question
\* stays until the person answers it.
Withdraw(r) ==
    /\ req[r] = "shown"
    /\ prog = "gone"
    /\ Mutation # "watch-off"
    /\ End(r, "withdrawn")
    /\ UNCHANGED <<prog, programs, ui, bash, crashed, asked>>

Next ==
    \/ Run \/ Yield \/ Return \/ Gone
    \/ \E r \in Reqs : Send(r) \/ Show(r) \/ GiveUp(r) \/ Answer(r) \/ Esc(r) \/ Withdraw(r)

\* fx withdraws, gives up, and returns. The person, the program, and the model
\* are not forced: a person may never answer, and a program may never exit.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Return)
    /\ \A r \in Reqs : WF_vars(Withdraw(r)) /\ WF_vars(GiveUp(r))

-----------------------------------------------------------------------------
\* Rules.

TypeOK ==
    /\ prog \in {"none", "running", "gone"}
    /\ programs \in 0..MaxPrograms
    /\ ui \in BOOLEAN
    /\ bash \in {"idle", "first", "yielded"}
    /\ req \in [Reqs -> {"none", "queued", "shown", "done"}]
    /\ lock \in Reqs \cup {NoReq}
    /\ slot \in Reqs \cup {NoReq}
    /\ crashed \in BOOLEAN
    /\ asked \in 0..Cardinality(Reqs)
    /\ told \in [Reqs -> {"none", "answer", "esc", "withdrawn", "gave-up", "no-ui", "unavailable"}]

\* A question never goes into a full slot, so the assert never fires.
NoCrash == ~crashed

\* One question at most is on screen.
OneShown == Cardinality({r \in Reqs : req[r] = "shown"}) <= 1

\* The slot and the lock belong to a question on screen, or to no one.
SlotIsShown == slot # NoReq => req[slot] = "shown"
LockIsShown == lock # NoReq => req[lock] = "shown"

\* A request is open only inside the first bash call, which the bridge belongs to.
OpenOnlyInFirstCall == \A r \in Reqs : Open(r) => bash = "first"

\* No question opens on a host without a question UI.
NoQuestionWithoutUi == ~ui => \A r \in Reqs : req[r] # "shown"

\* The bash call never yields while a request is open.
NoYieldWhileOpen == [][bash = "first" /\ bash' = "yielded" => NoneOpen]_vars

\* A question whose program is gone ends, even when no one answers it.
QuestionEndsWhenGone ==
    \A r \in Reqs : [](req[r] = "shown" /\ prog = "gone" => <>(req[r] # "shown"))

\* A bash call whose program is gone returns.
CallReturnsWhenGone == [](Inside /\ prog = "gone" => <>(bash = "idle"))

-----------------------------------------------------------------------------
\* Witnesses: each must be violated, to show that TLC reaches that case.

NeverAnswered == \A r \in Reqs : told[r] # "answer"
NeverWithdrawn == \A r \in Reqs : told[r] # "withdrawn"
NeverGaveUp == \A r \in Reqs : told[r] # "gave-up"
NeverEsc == \A r \in Reqs : told[r] # "esc"
NeverNoUi == \A r \in Reqs : told[r] # "no-ui"
NeverUnavailable == \A r \in Reqs : told[r] # "unavailable"
\* A second question from one program opened after the first one ended.
NeverTwoAsked == asked < 2

=============================================================================
