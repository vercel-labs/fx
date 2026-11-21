---------------------------- MODULE HookTurn ----------------------------
(* One turn of fx with user hooks: the model loop, the PreToolUse and
   PermissionDenied hooks around each tool call, the Stop hook on each final
   reply, and a person who may cancel at any time.

   The code it follows, cited by path and name:
     src/core/agent/runtime/orchestrator.zig, processQueuedPromptLoop
       the cancel flag is read after each model reply; the PreToolUse loop
       over the prepared calls breaks once the flag is set; the Stop gate runs
       the user's Stop hooks on the reply, and a continue request reopens the
       loop
     src/core/agent/runtime/lifecycle.zig, dispatchPreToolUseCheckpoint and
       prepareToolCallFromCheckpoint
       each returns Cancelled before a call, when the cancel flag is set
     src/core/agent/runtime/user_hooks.zig: permissionDenied, stop, preToolUse,
       stopCap, and max_denied_retries
       each cap is checked before its hook starts; a retry or a continue answer
       adds one; deny blocks the call; allow sets the permission hint
     src/core/tooling/tool_admission.zig, the hook_permission == .allow branch
       a hook's allow approves the call once, without the prompt
     src/hooks/merge.zig, the failure arm of the merge
       a failed hook is a deny when it is set to block, and no opinion when it
       is set to proceed: a failure never allows
     src/hooks/limits.zig: stop_continuations_per_turn = 3

   Actions: a model call (it asks for a tool or gives its final reply), a
   PreToolUse answer (none, allow, deny, or fail), the permission check (the
   environment picks its result), a PermissionDenied answer (retry or not), a
   Stop answer (none, continue, or fail), a tool run, the step limit, the
   person's cancel, and the end of a cancelled turn. Each hook start and each
   answer is its own action, so a cancel can come between them. The turn is
   bounded by MaxSteps model calls (agent_step_limit); every loop back to the
   model takes one, so the turn ends.

   Modelling choices:
   - Every hook is configured, and no configured ask rule overrides an allow.
   - A failed hook is a deny when its on_failure is block, and no opinion when
     it is proceed. The choice is fixed for the turn (failBlocks).
   - A cancel sets a flag. Each work action checks the flag before it works:
     a model call, a hook start, a hook answer, and the permission check
     (RespectCancel); a tool run (RunChecksCancel). CancelEnd then ends the
     turn, so a cancelled turn still ends.
   - A tool run records its grant: a hook allow ("hook") or the permission
     check ("permit"). ranNoGrant is set when a run has no grant, or when its
     grant came from a hook that did not answer allow.
   - A Stop answer of fail never continues the turn.
   - The state records one call at a time. Sub-agents, compaction, steering,
     and the other hook events are not modelled.

   Constants select the design or a planted defect:
     MaxSteps        model calls one turn may make
     StopCapOn       TRUE checks the Stop cap before the Stop hook starts
     RespectCancel   TRUE: the work actions that model calls, hook starts and
                     answers, and the permission check stop once the person
                     has cancelled
     FailAllows      FALSE: a failed PreToolUse hook gives no opinion
     RetryCapOn      TRUE checks the PermissionDenied cap before the hook starts
     RunChecksCancel TRUE: a tool run checks the cancel flag before it runs *)
EXTENDS Naturals

CONSTANTS MaxSteps, StopCapOn, RespectCancel, FailAllows, RetryCapOn, RunChecksCancel

StopCap == 3   \* src/hooks/limits.zig: stop_continuations_per_turn
RetryCap == 3  \* src/core/agent/runtime/user_hooks.zig: max_denied_retries

VARIABLES phase,      \* the turn's place; see Phases
          steps,      \* model calls so far
          conts,      \* Stop continuations used
          retries,    \* PermissionDenied retries used
          cancelled,  \* the person cancelled (a flag, checked by each work action)
          failBlocks, \* a failed hook is a deny (on_failure = block)
          afterCancel,\* a model call, a hook start, or a tool run happened after a cancel
          verdict,    \* the current call's PreToolUse answer
          grant,      \* how the current call was granted to run
          ranDenied,  \* a call that a PreToolUse hook denied ran
          ranNoGrant  \* a call ran with no grant, or with a grant a hook did not give

vars == <<phase, steps, conts, retries, cancelled, failBlocks, afterCancel,
          verdict, grant, ranDenied, ranNoGrant>>

Phases == {"model", "tool", "tool_hook", "gate", "perm_hook", "run",
           "stop", "stop_hook", "done", "cancelled"}
Terminal == {"done", "cancelled"}
Verdicts == {"-", "none", "allow", "deny", "fail"}
Grants == {"none", "hook", "permit"}

\* The work that a cancel stops: a model call, a hook start, a hook answer, and
\* the permission check, once the person has cancelled (RespectCancel).
Stopped == RespectCancel /\ cancelled
\* A tool run checks the cancel flag before it runs (RunChecksCancel).
RunStopped == RunChecksCancel /\ cancelled

TypeOK ==
    /\ phase \in Phases
    /\ steps \in 0..MaxSteps
    /\ conts \in 0..MaxSteps
    /\ retries \in 0..MaxSteps
    /\ cancelled \in BOOLEAN
    /\ failBlocks \in BOOLEAN
    /\ afterCancel \in BOOLEAN
    /\ verdict \in Verdicts
    /\ grant \in Grants
    /\ ranDenied \in BOOLEAN
    /\ ranNoGrant \in BOOLEAN

Init ==
    /\ phase = "model"
    /\ steps = 0
    /\ conts = 0
    /\ retries = 0
    /\ cancelled = FALSE
    /\ failBlocks \in BOOLEAN
    /\ afterCancel = FALSE
    /\ verdict = "-"
    /\ grant = "none"
    /\ ranDenied = FALSE
    /\ ranNoGrant = FALSE

\* The person cancels the turn. The flag is set; each work action checks it
\* before it works, so the turn stops at its next check.
Cancel ==
    /\ ~cancelled
    /\ phase \notin Terminal
    /\ cancelled' = TRUE
    /\ UNCHANGED <<phase, steps, conts, retries, failBlocks, afterCancel, verdict,
                   grant, ranDenied, ranNoGrant>>

\* A cancelled turn ends in the cancelled phase. This is an action of the turn,
\* so the turn reaches it under the fairness below.
CancelEnd ==
    /\ cancelled
    /\ phase \notin Terminal
    /\ phase' = "cancelled"
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, afterCancel,
                   verdict, grant, ranDenied, ranNoGrant>>

\* A model call. The model asks for a tool, or gives its final reply.
CallModel ==
    /\ phase = "model"
    /\ steps < MaxSteps
    /\ ~Stopped
    /\ steps' = steps + 1
    /\ afterCancel' = (afterCancel \/ cancelled)
    /\ (\E asksTool \in BOOLEAN: phase' = IF asksTool THEN "tool" ELSE "stop")
    /\ UNCHANGED <<conts, retries, cancelled, failBlocks, verdict, grant,
                   ranDenied, ranNoGrant>>

\* The step limit ends the turn (agent_step_limit).
StepLimit ==
    /\ phase = "model"
    /\ steps = MaxSteps
    /\ phase' = "done"
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, afterCancel,
                   verdict, grant, ranDenied, ranNoGrant>>

\* The final reply goes to the Stop hook when the cap has room. A capped turn
\* ends without starting it (src/core/agent/runtime/user_hooks.zig, stop).
StopBegin ==
    /\ phase = "stop"
    /\ ~Stopped
    /\ IF StopCapOn /\ conts >= StopCap
         THEN (phase' = "done" /\ afterCancel' = afterCancel)
         ELSE (phase' = "stop_hook" /\ afterCancel' = (afterCancel \/ cancelled))
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, verdict, grant,
                   ranDenied, ranNoGrant>>

\* The Stop hook answers. A continue answer reopens the loop. A failed hook
\* never continues the turn.
StopAnswer ==
    /\ phase = "stop_hook"
    /\ ~Stopped
    /\ (\E answer \in {"none", "continue", "fail"}:
          IF answer = "continue"
            THEN (conts' = conts + 1 /\ phase' = "model")
            ELSE (conts' = conts /\ phase' = "done"))
    /\ UNCHANGED <<steps, retries, cancelled, failBlocks, afterCancel, verdict,
                   grant, ranDenied, ranNoGrant>>

\* A PreToolUse hook starts for the call the model asked for.
ToolStart ==
    /\ phase = "tool"
    /\ ~Stopped
    /\ phase' = "tool_hook"
    /\ afterCancel' = (afterCancel \/ cancelled)
    /\ verdict' = "-"
    /\ grant' = "none"
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, ranDenied,
                   ranNoGrant>>

\* The PreToolUse hook answers. deny blocks the call. allow runs it, approved by
\* the hook. none, and a failed hook with proceed, leave it to the permission
\* check. A failed hook with block denies the call. FailAllows is the planted
\* defect that reads a failed hook as an allow.
ToolAnswer ==
    /\ phase = "tool_hook"
    /\ ~Stopped
    /\ (\E answer \in {"none", "allow", "deny", "fail"}:
          /\ verdict' = answer
          /\ IF answer = "allow"
               THEN (phase' = "run" /\ grant' = "hook")
             ELSE IF answer = "deny"
               THEN (phase' = "model" /\ grant' = "none")
             ELSE IF answer = "fail" /\ failBlocks
               THEN (phase' = "model" /\ grant' = "none")
             ELSE IF answer = "fail" /\ FailAllows
               THEN (phase' = "run" /\ grant' = "hook")
             ELSE (phase' = "gate" /\ grant' = "none"))
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, afterCancel,
                   ranDenied, ranNoGrant>>

\* The permission check. Its result is the environment's choice. A denied call
\* starts the PermissionDenied hook while the cap has room
\* (src/core/agent/runtime/user_hooks.zig, permissionDenied).
Gate ==
    /\ phase = "gate"
    /\ ~Stopped
    /\ (\E permitted \in BOOLEAN:
          IF permitted
            THEN (phase' = "run" /\ grant' = "permit" /\ afterCancel' = afterCancel)
          ELSE IF (~RetryCapOn) \/ (retries < RetryCap)
            THEN (phase' = "perm_hook" /\ grant' = grant
                  /\ afterCancel' = (afterCancel \/ cancelled))
            ELSE (phase' = "model" /\ grant' = grant /\ afterCancel' = afterCancel))
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, verdict,
                   ranDenied, ranNoGrant>>

\* The PermissionDenied hook answers. A retry lets the model ask again.
PermAnswer ==
    /\ phase = "perm_hook"
    /\ ~Stopped
    /\ (\E retry \in BOOLEAN:
          IF retry
            THEN (retries' = retries + 1 /\ phase' = "model")
            ELSE (retries' = retries /\ phase' = "model"))
    /\ UNCHANGED <<steps, conts, cancelled, failBlocks, afterCancel, verdict,
                   grant, ranDenied, ranNoGrant>>

\* The tool runs. It records the two safety facts the invariants check. The run
\* checks the cancel flag first (RunChecksCancel); a run that ignores it is
\* recorded as work after a cancel.
RunTool ==
    /\ phase = "run"
    /\ ~RunStopped
    /\ phase' = "model"
    /\ ranDenied' = (ranDenied \/ (verdict = "deny"))
    /\ ranNoGrant' = (ranNoGrant \/ (grant = "none") \/ ((grant = "hook") /\ (verdict # "allow")))
    /\ afterCancel' = (afterCancel \/ cancelled)
    /\ UNCHANGED <<steps, conts, retries, cancelled, failBlocks, verdict, grant>>

TurnStep == CallModel \/ StepLimit \/ StopBegin \/ StopAnswer \/ ToolStart
            \/ ToolAnswer \/ Gate \/ PermAnswer \/ RunTool \/ CancelEnd

Next == Cancel \/ TurnStep

\* The turn's own steps are fair, and so is the end of a cancelled turn. The
\* person's cancel is not assumed to happen.
Spec == Init /\ [][Next]_vars /\ WF_vars(TurnStep)

\* The Stop continuations never pass the cap.
StopCapBound == conts <= StopCap

\* The PermissionDenied retries never pass the cap.
RetryCapBound == retries <= RetryCap

\* A tool that a PreToolUse hook denied never runs.
NoDeniedRun == ~ranDenied

\* A tool runs only with a grant: the permission check, or a hook that allowed it.
ToolRunsWithGrant == ~ranNoGrant

\* No model call, hook start, or tool run happens after a cancel. A cancel sets a
\* flag that each of these checks first (Stopped and RunStopped); a planted defect
\* that drops one of those checks lets its work run after the cancel, and this
\* invariant catches it.
NoWorkAfterCancel == ~afterCancel

\* Every turn reaches done or cancelled.
TurnEnds == <>(phase \in Terminal)

=============================================================================
