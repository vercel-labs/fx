---------------------------- MODULE WebFetchDns ----------------------------
(***************************************************************************)
(* DNS resolution with cancellation and hop deadline in                    *)
(* src/tools/web/http_fetch.zig (resolveWithDeadline).                     *)
(*                                                                         *)
(* Actors:                                                                 *)
(*   - Fetch caller (turn thread): starts DNS lookup, waits on cancelFlag  *)
(*     (TUI Esc, fx ask Ctrl+C, ACP session/cancel or EOF, subagent stop)  *)
(*     and hop deadline, then returns and frees/reuses callerMem.          *)
(*   - Lookup thread: runs HostName.lookup (getaddrinfo). May finish fast, *)
(*     stall, or ignore/retry SIGIO signals, and may finish after the      *)
(*     caller has returned.                                                *)
(*   - Hop deadline: expires at default_hop_timeout_ms (60 s).             *)
(*                                                                         *)
(* Designs:                                                                *)
(*   "current"  - ResolveCondition.cancelled returns FALSE; Select waits   *)
(*                for lookup or 60 s deadline, and Select.cancel joins.    *)
(*   "design-a" - ResolveCondition.cancelled reads options.cancel_flag;    *)
(*                Select.cancel sends SIGIO and joins the lookup thread.   *)
(*   "design-b" - Detached OpenJob-style walk-away lookup: lookup owns its *)
(*                own c_allocator memory and handoff atomic; caller walks  *)
(*                away immediately on cancel or deadline.                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Design,     \* "current" | "design-a" | "design-b"
          Mutant,     \* "none" | "a-no-check" | "b-caller-frees-early"
                      \* | "b-non-atomic" | "b-reads-caller-flag" | "b-no-deadline"
          SignalMode, \* "all" | "interruptible"
          Class       \* "all" | "ideal" | "nonideal"

VARIABLES fetchPhase,            \* "running" | "cancelling_select"
                                 \* | "returned_ok" | "returned_cancelled" | "returned_timeout"
          lookupPhase,           \* "resolving" | "finished" | "aborted_by_signal"
          lookupIgnoresSignals,  \* BOOLEAN
          handoff,               \* "running" | "handed" | "abandoned"
          callerSeenHandoff,     \* "none" | "running" | "handed"
          jobSeenHandoff,        \* "none" | "running" | "abandoned"
          cancelFlag,            \* BOOLEAN
          deadlineExpired,       \* BOOLEAN
          callerMem,             \* "live" | "freed" | "reused"
          jobMem,                \* "live" | "freed"
          lateBadWrite,          \* BOOLEAN
          promptBoundHeld,       \* BOOLEAN
          missedDeadline         \* BOOLEAN

vars == <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
          callerSeenHandoff, jobSeenHandoff, cancelFlag, deadlineExpired,
          callerMem, jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

FetchReturned ==
    fetchPhase \in {"returned_ok", "returned_cancelled", "returned_timeout"}

TypeOK ==
    /\ fetchPhase \in {"running", "cancelling_select",
                       "returned_ok", "returned_cancelled", "returned_timeout"}
    /\ lookupPhase \in {"resolving", "finished", "aborted_by_signal"}
    /\ lookupIgnoresSignals \in BOOLEAN
    /\ handoff \in {"running", "handed", "abandoned"}
    /\ callerSeenHandoff \in {"none", "running", "handed"}
    /\ jobSeenHandoff \in {"none", "running", "handed", "abandoned"}
    /\ cancelFlag \in BOOLEAN
    /\ deadlineExpired \in BOOLEAN
    /\ callerMem \in {"live", "freed", "reused"}
    /\ jobMem \in {"live", "freed"}
    /\ lateBadWrite \in BOOLEAN
    /\ promptBoundHeld \in BOOLEAN
    /\ missedDeadline \in BOOLEAN

Init ==
    /\ fetchPhase = "running"
    /\ lookupPhase = "resolving"
    /\ lookupIgnoresSignals \in (IF SignalMode = "interruptible" THEN {FALSE} ELSE BOOLEAN)
    /\ handoff = "running"
    /\ callerSeenHandoff = "none"
    /\ jobSeenHandoff = "none"
    /\ cancelFlag = FALSE
    /\ deadlineExpired = FALSE
    /\ callerMem = "live"
    /\ jobMem = "live"
    /\ lateBadWrite = FALSE
    /\ promptBoundHeld = FALSE
    /\ missedDeadline = FALSE

\* Turn cancel arrives (TUI Esc, fx ask SIGINT, ACP session/cancel or EOF, subagent stop).
TurnCancel ==
    /\ Class /= "ideal"
    /\ ~cancelFlag
    /\ fetchPhase = "running"
    /\ cancelFlag' = TRUE
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, jobSeenHandoff, deadlineExpired,
                   callerMem, jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

\* Hop deadline (60 s) expires.
HopDeadlineExpire ==
    /\ Class /= "ideal"
    /\ ~deadlineExpired
    /\ fetchPhase = "running"
    /\ deadlineExpired' = TRUE
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, jobSeenHandoff, cancelFlag,
                   callerMem, jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

\* Lookup finishes naturally (may happen before or after fetch returned).
LookupComplete ==
    /\ lookupPhase = "resolving"
    /\ lookupPhase' = "finished"
    /\ IF Design \in {"current", "design-a"}
       THEN /\ IF callerMem /= "live"
               THEN lateBadWrite' = TRUE
               ELSE lateBadWrite' = lateBadWrite
            /\ handoff' = handoff
            /\ jobMem' = jobMem
       ELSE IF Mutant = "b-reads-caller-flag" /\ callerMem /= "live"
            THEN /\ lateBadWrite' = TRUE
                 /\ handoff' = handoff
                 /\ jobMem' = jobMem
            ELSE IF Mutant = "b-non-atomic"
                 THEN /\ handoff' = handoff
                      /\ jobMem' = jobMem
                      /\ lateBadWrite' = lateBadWrite
                 ELSE IF handoff = "running"
                      THEN /\ handoff' = "handed"
                           /\ jobMem' = jobMem
                           /\ lateBadWrite' = lateBadWrite
                      ELSE \* Abandoned by caller: lookup frees its own result/memory.
                           /\ handoff' = handoff
                           /\ IF jobMem = "freed"
                              THEN lateBadWrite' = TRUE
                              ELSE lateBadWrite' = lateBadWrite
                           /\ jobMem' = "freed"
    /\ UNCHANGED <<fetchPhase, lookupIgnoresSignals, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, promptBoundHeld, missedDeadline>>

\* Non-atomic split publish for mutant b-non-atomic.
JobReadHandoffNonAtomic ==
    /\ Design = "design-b" /\ Mutant = "b-non-atomic"
    /\ lookupPhase = "finished"
    /\ jobSeenHandoff = "none"
    /\ jobSeenHandoff' = handoff
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, cancelFlag, deadlineExpired,
                   callerMem, jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

JobWriteHandoffNonAtomic ==
    /\ Design = "design-b" /\ Mutant = "b-non-atomic"
    /\ lookupPhase = "finished"
    /\ jobSeenHandoff /= "none"
    /\ IF jobSeenHandoff = "running"
       THEN /\ handoff' = "handed"
            /\ IF handoff /= "running"
               THEN lateBadWrite' = TRUE
               ELSE lateBadWrite' = lateBadWrite
            /\ jobMem' = jobMem
       ELSE /\ handoff' = handoff
            /\ IF jobMem = "freed" THEN lateBadWrite' = TRUE ELSE lateBadWrite' = lateBadWrite
            /\ jobMem' = "freed"
    /\ jobSeenHandoff' = "none"
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, callerSeenHandoff,
                   cancelFlag, deadlineExpired,
                   callerMem, promptBoundHeld, missedDeadline>>

\* Lookup succeeded before cancel/deadline fired -> caller takes result and returns ok.
FetchTakeSuccess ==
    /\ fetchPhase = "running"
    /\ lookupPhase = "finished"
    /\ IF Design = "design-b" THEN handoff = "handed" ELSE TRUE
    /\ fetchPhase' = "returned_ok"
    /\ IF Design = "design-b"
       THEN /\ IF jobMem = "freed" THEN lateBadWrite' = TRUE ELSE lateBadWrite' = lateBadWrite
            /\ jobMem' = "freed"
       ELSE /\ jobMem' = "freed"
            /\ lateBadWrite' = lateBadWrite
    /\ UNCHANGED <<lookupPhase, lookupIgnoresSignals, handoff, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, promptBoundHeld, missedDeadline>>

\* Current & Design A: ResolveWatch fires on cancel or deadline -> enters cancelling_select.
WatchTriggerSelectCancel ==
    /\ Design \in {"current", "design-a"}
    /\ fetchPhase = "running"
    /\ LET seesCancel == (Design = "design-a" /\ Mutant /= "a-no-check" /\ cancelFlag)
       IN /\ (seesCancel \/ deadlineExpired)
          /\ fetchPhase' = "cancelling_select"
          /\ IF cancelFlag /\ ~seesCancel
             THEN promptBoundHeld' = TRUE
             ELSE promptBoundHeld' = promptBoundHeld
    /\ UNCHANGED <<lookupPhase, lookupIgnoresSignals, handoff, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, jobMem, lateBadWrite, missedDeadline>>

\* Current & Design A: Select.cancel sends SIGIO to lookup.
SelectCancelSignal ==
    /\ Design \in {"current", "design-a"}
    /\ fetchPhase = "cancelling_select"
    /\ lookupPhase = "resolving"
    /\ IF lookupIgnoresSignals
       THEN /\ lookupPhase' = "resolving"
            /\ IF cancelFlag THEN promptBoundHeld' = TRUE ELSE promptBoundHeld' = promptBoundHeld
       ELSE /\ lookupPhase' = "aborted_by_signal"
            /\ promptBoundHeld' = promptBoundHeld
    /\ UNCHANGED <<fetchPhase, lookupIgnoresSignals, handoff, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, jobMem, lateBadWrite, missedDeadline>>

\* Current & Design A: Select.cancel finishes ONLY once lookup is no longer resolving.
SelectCancelFinish ==
    /\ Design \in {"current", "design-a"}
    /\ fetchPhase = "cancelling_select"
    /\ lookupPhase \in {"finished", "aborted_by_signal"}
    /\ fetchPhase' = IF cancelFlag THEN "returned_cancelled" ELSE "returned_timeout"
    /\ jobMem' = "freed"
    /\ UNCHANGED <<lookupPhase, lookupIgnoresSignals, handoff, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, lateBadWrite, promptBoundHeld, missedDeadline>>

\* Current without ResolveCondition.cancelled: if cancel arrives and lookup stays blocked,
\* current ignores cancelFlag until the 60 s hop deadline.
CurrentWaitIgnoresCancel ==
    /\ Design = "current"
    /\ fetchPhase = "running"
    /\ cancelFlag
    /\ ~deadlineExpired
    /\ lookupPhase = "resolving"
    /\ promptBoundHeld' = TRUE
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, jobSeenHandoff, cancelFlag, deadlineExpired,
                   callerMem, jobMem, lateBadWrite, missedDeadline>>

\* Design B: non-atomic split check for mutant b-non-atomic.
CallerReadHandoffNonAtomic ==
    /\ Design = "design-b" /\ Mutant = "b-non-atomic"
    /\ fetchPhase = "running"
    /\ (cancelFlag \/ (deadlineExpired /\ Mutant /= "b-no-deadline"))
    /\ callerSeenHandoff = "none"
    /\ callerSeenHandoff' = IF handoff = "handed" THEN "handed" ELSE "running"
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   jobSeenHandoff, cancelFlag, deadlineExpired,
                   callerMem, jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

\* Design B: caller sees cancel or deadline and walks away immediately.
CallerWalkAway ==
    /\ Design = "design-b"
    /\ fetchPhase = "running"
    /\ (cancelFlag \/ (deadlineExpired /\ Mutant /= "b-no-deadline"))
    /\ (Mutant /= "b-non-atomic" \/ callerSeenHandoff /= "none")
    /\ fetchPhase' = IF cancelFlag THEN "returned_cancelled" ELSE "returned_timeout"
    /\ IF Mutant = "b-non-atomic"
       THEN IF callerSeenHandoff = "running"
            THEN /\ handoff' = "abandoned"
                 /\ jobMem' = jobMem
                 /\ lateBadWrite' = lateBadWrite
            ELSE /\ handoff' = handoff
                 /\ IF jobMem = "freed" THEN lateBadWrite' = TRUE ELSE lateBadWrite' = lateBadWrite
                 /\ jobMem' = "freed"
       ELSE IF handoff = "running"
            THEN /\ handoff' = "abandoned"
                 /\ IF Mutant = "b-caller-frees-early"
                    THEN jobMem' = "freed"
                    ELSE jobMem' = jobMem
                 /\ lateBadWrite' = lateBadWrite
            ELSE /\ handoff' = handoff
                 /\ IF jobMem = "freed" THEN lateBadWrite' = TRUE ELSE lateBadWrite' = lateBadWrite
                 /\ jobMem' = "freed"
    /\ UNCHANGED <<lookupPhase, lookupIgnoresSignals, callerSeenHandoff, jobSeenHandoff,
                   cancelFlag, deadlineExpired, callerMem, promptBoundHeld, missedDeadline>>

\* Mutant b-no-deadline: deadlineExpired arrives, lookup still resolving, caller misses deadline.
NoDeadlineStall ==
    /\ Design = "design-b" /\ Mutant = "b-no-deadline"
    /\ fetchPhase = "running"
    /\ deadlineExpired
    /\ ~cancelFlag
    /\ lookupPhase = "resolving"
    /\ missedDeadline' = TRUE
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, jobSeenHandoff, cancelFlag, deadlineExpired,
                   callerMem, jobMem, lateBadWrite, promptBoundHeld>>

\* Once fetch returns, caller frees its arena / reuses its session memory.
CallerFreeAndReuse ==
    /\ FetchReturned
    /\ callerMem \in {"live", "freed"}
    /\ callerMem' = IF callerMem = "live" THEN "freed" ELSE "reused"
    /\ UNCHANGED <<fetchPhase, lookupPhase, lookupIgnoresSignals, handoff,
                   callerSeenHandoff, jobSeenHandoff, cancelFlag, deadlineExpired,
                   jobMem, lateBadWrite, promptBoundHeld, missedDeadline>>

Done ==
    /\ FetchReturned
    /\ callerMem = "reused"
    /\ (Design /= "design-b" \/ lookupPhase = "finished")
    /\ UNCHANGED vars

Next ==
    \/ TurnCancel
    \/ HopDeadlineExpire
    \/ LookupComplete
    \/ JobReadHandoffNonAtomic
    \/ JobWriteHandoffNonAtomic
    \/ FetchTakeSuccess
    \/ WatchTriggerSelectCancel
    \/ SelectCancelSignal
    \/ SelectCancelFinish
    \/ CurrentWaitIgnoresCancel
    \/ CallerReadHandoffNonAtomic
    \/ CallerWalkAway
    \/ NoDeadlineStall
    \/ CallerFreeAndReuse
    \/ Done

Spec == Init /\ [][Next]_vars

FairSpec ==
    Spec
    /\ WF_vars(FetchTakeSuccess)
    /\ WF_vars(WatchTriggerSelectCancel)
    /\ WF_vars(SelectCancelSignal)
    /\ WF_vars(SelectCancelFinish)
    /\ WF_vars(CallerReadHandoffNonAtomic)
    /\ WF_vars(CallerWalkAway)
    /\ WF_vars(CallerFreeAndReuse)
    /\ WF_vars(JobReadHandoffNonAtomic)
    /\ WF_vars(JobWriteHandoffNonAtomic)

-----------------------------------------------------------------------------
(* Invariants and Temporal Properties *)

CancelIsPrompt ==
    ~promptBoundHeld

NoUseAfterReturn ==
    /\ ~lateBadWrite
    /\ (FetchReturned /\ Design = "design-b" /\ handoff = "handed") => (jobMem = "freed")

DeadlineStillWorks ==
    ~missedDeadline

BoundedCancel ==
    cancelFlag ~> FetchReturned

BoundedDeadline ==
    deadlineExpired ~> FetchReturned

=============================================================================
