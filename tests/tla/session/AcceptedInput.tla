--------------------------- MODULE AcceptedInput ---------------------------
(***************************************************************************)
(* Crash-safe accepted user prompts across fx persistence designs.         *)
(*                                                                         *)
(* Designs:                                                                *)
(*   - "a2" (landed): `input_accepted` and `input_withdrawn` records in    *)
(*     the session log plus atomic batch delivery of the normal `item`     *)
(*     (`user` or `steering`) and `input_delivered` carrying the prompt id *)
(*     (`src/core/session/session_adapter.zig` `recordInputAccepted`,      *)
(*     `writePieces` with `input_delivered`, `recordInputsWithdrawn`;      *)
(*     `src/core/agent/worker_runtime.zig` `accepted_input_hooks`;         *)
(*     `src/core/app/app_session_runtime.zig`                              *)
(*     `restorePendingAcceptedInputs`).                                    *)
(*   - "current" (fx before the fix): queued prompts live only in          *)
(*     `WorkerRuntime.queued_prompts` in RAM; `Boundary` and `TurnStarts`  *)
(*     pop RAM before writing the log; `Restart` restores nothing;         *)
(*     `SessionSwitch` clears RAM silently.                                *)
(*   - "a" (rejected): accept and withdraw records in the session log plus *)
(*     a single-line carrier item carrying the prompt id and text.         *)
(*   - "b" (rejected): an atomic pending-input file beside the log plus a  *)
(*     single-line carrier item in the log for deduplication on resume.    *)
(*                                                                         *)
(* Models process crashes (all written log lines and atomic file renames   *)
(* survive a kill -9). Power loss before fsync is omitted here and         *)
(* modeled separately in tests/tla/session_manager/SessionLog.tla.         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxPrompts,   \* upper bound on prompt ids (Prompts == 1..MaxPrompts)
    MaxCrashes,   \* upper bound on process crashes
    MaxSwitches,  \* upper bound on session switches
    Design,       \* "current" | "a" | "a2" | "b"
    Mutant        \* "none" | "a_two_lines" | "a_show_before_write" | "b_no_dedupe" | "a_withdraw_after_drop" | "a2_marker_later" | "a2_withdraw_before_composer"

ASSUME MaxPrompts \in Nat /\ MaxPrompts >= 1
ASSUME MaxCrashes \in Nat
ASSUME MaxSwitches \in Nat
ASSUME Design \in {"current", "a", "a2", "b"}
ASSUME Mutant \in {
    "none",
    "a_two_lines",
    "a_show_before_write",
    "b_no_dedupe",
    "a_withdraw_after_drop",
    "a2_marker_later",
    "a2_withdraw_before_composer"
}

Prompts == 1..MaxPrompts
None == 0

LogKinds == {"start", "commit", "interrupt", "accepted", "withdrawn", "delivered", "item"}
ItemTypes == {"none", "steering", "user", "carrier", "carrier_id"}
LogRecs == [kind: LogKinds, type: ItemTypes, id: Prompts \cup {None}]

InFlightKinds == {"none", "cur_boundary", "cur_turn", "a_pop", "a_line2", "a2_marker_later", "b_rewrite"}
InFlightRecs == [kind: InFlightKinds, id: Prompts \cup {None}]
NoInFlight == [kind |-> "none", id |-> None]

LogRec(k, t, pid) == [kind |-> k, type |-> t, id |-> pid]

VARIABLES
    memQueue,               \* Seq(Prompts): worker's in-memory prompt queue
    composer,               \* Seq(Prompts): Design A2 composer restored prompts
    log,                    \* Seq(LogRecs): session log lines written so far
    pendingFile,            \* Seq(Prompts): Design B's pending.json contents
    delivered,              \* [Prompts -> Nat]: multiset of delivered prompt ids
    screen,                 \* SUBSET Prompts: accepted rows currently drawn
    everShown,              \* SUBSET Prompts: every id ever shown as accepted
    withdrawn,              \* SUBSET Prompts: ids retracted by the user
    restoredToComposer,     \* SUBSET Prompts: ids restored into composer and withdrawn
    failedAccept,           \* SUBSET Prompts: ids admitted fail-open with no accepted record
    notices,                \* SUBSET Prompts: ids covered by a user-visible notice
    turnOpen,               \* BOOLEAN: whether a turn is open in the worker
    crashed,                \* BOOLEAN: TRUE while process is down after a crash
    inSession,              \* BOOLEAN: TRUE while user is in the modeled session
    afterRestart,           \* BOOLEAN: TRUE after a Restart until next Crash/Switch
    submitted,              \* SUBSET Prompts: ids submitted so far
    acceptedOrder,          \* Seq(Prompts): admission order of submitted ids
    crashes,                \* 0..MaxCrashes: crash count
    switches,               \* 0..MaxSwitches: session switch count
    ambientTurns,           \* 0..1: bound on ambient turns opened without a prompt
    inFlight,               \* InFlightRecs: active two-step delivery/turn-start state
    inFlightAccept,         \* SUBSET Prompts: Mutant a_show_before_write pending write
    inFlightWithdraw,       \* SUBSET Prompts: Mutant a_withdraw_after_drop pending write
    pendingRestoreWithdraw, \* Seq(Prompts): Design A2 restored ids awaiting withdrawn batch
    pendingRestoreComposer  \* Seq(Prompts): Mutant a2_withdraw_before_composer awaiting composer fill

vars == <<
    memQueue, composer, log, pendingFile, delivered, screen, everShown,
    withdrawn, restoredToComposer, failedAccept, notices, turnOpen, crashed,
    inSession, afterRestart, submitted, acceptedOrder, crashes, switches,
    ambientTurns, inFlight, inFlightAccept, inFlightWithdraw,
    pendingRestoreWithdraw, pendingRestoreComposer
>>

-----------------------------------------------------------------------------
(* Helpers *)

Range(seq) == {seq[i] : i \in 1..Len(seq)}
MemIds == Range(memQueue)
InSeq(seq, x) == \E i \in 1..Len(seq) : seq[i] = x
RemoveFromSeq(seq, x) == SelectSeq(seq, LAMBDA e : e # x)

CountKind(l, k) == Cardinality({i \in 1..Len(l) : l[i].kind = k})
LogTurnOpen(l) == CountKind(l, "start") > (CountKind(l, "commit") + CountKind(l, "interrupt"))

HasAccepted(l, pid) ==
    \E i \in 1..Len(l) : l[i].kind = "accepted" /\ l[i].id = pid

HasCarrier(l, pid) ==
    \E i \in 1..Len(l) : l[i].kind = "item" /\ l[i].type \in {"carrier", "carrier_id"} /\ l[i].id = pid

HasDelivered(l, pid) ==
    \E i \in 1..Len(l) : l[i].kind = "delivered" /\ l[i].id = pid

HasWithdrawn(l, pid) ==
    \E i \in 1..Len(l) : l[i].kind = "withdrawn" /\ l[i].id = pid

RestoreA(l) ==
    LET accSeq == SelectSeq(l, LAMBDA r : r.kind = "accepted")
        ids == [i \in 1..Len(accSeq) |-> accSeq[i].id]
    IN SelectSeq(ids, LAMBDA pid : ~HasCarrier(l, pid) /\ ~HasWithdrawn(l, pid))

RestoreA2(l) ==
    LET accSeq == SelectSeq(l, LAMBDA r : r.kind = "accepted")
        ids == [i \in 1..Len(accSeq) |-> accSeq[i].id]
    IN SelectSeq(ids, LAMBDA pid : ~HasDelivered(l, pid) /\ ~HasWithdrawn(l, pid))

RestoreB(l, pf) ==
    IF Mutant = "b_no_dedupe"
      THEN pf
      ELSE SelectSeq(pf, LAMBDA pid : ~HasCarrier(l, pid))

Pos(seq, x) == CHOOSE k \in 1..Len(seq) : seq[k] = x

RestoreIdle == pendingRestoreWithdraw = <<>> /\ pendingRestoreComposer = <<>>

-----------------------------------------------------------------------------
(* Type invariant and initial state *)

TypeOK ==
    /\ memQueue \in Seq(Prompts)
    /\ Len(memQueue) <= MaxPrompts
    /\ composer \in Seq(Prompts)
    /\ Len(composer) <= MaxPrompts
    /\ log \in Seq(LogRecs)
    /\ pendingFile \in Seq(Prompts)
    /\ Len(pendingFile) <= MaxPrompts
    /\ \A id \in Prompts : delivered[id] \in Nat
    /\ screen \subseteq Prompts
    /\ everShown \subseteq Prompts
    /\ withdrawn \subseteq Prompts
    /\ restoredToComposer \subseteq Prompts
    /\ failedAccept \subseteq Prompts
    /\ notices \subseteq Prompts
    /\ turnOpen \in BOOLEAN
    /\ crashed \in BOOLEAN
    /\ inSession \in BOOLEAN
    /\ afterRestart \in BOOLEAN
    /\ submitted \subseteq Prompts
    /\ acceptedOrder \in Seq(Prompts)
    /\ Len(acceptedOrder) <= MaxPrompts
    /\ crashes \in 0..MaxCrashes
    /\ switches \in 0..MaxSwitches
    /\ ambientTurns \in 0..1
    /\ inFlight \in InFlightRecs
    /\ inFlightAccept \subseteq Prompts
    /\ inFlightWithdraw \subseteq Prompts
    /\ pendingRestoreWithdraw \in Seq(Prompts)
    /\ Len(pendingRestoreWithdraw) <= MaxPrompts
    /\ pendingRestoreComposer \in Seq(Prompts)
    /\ Len(pendingRestoreComposer) <= MaxPrompts

Init ==
    /\ memQueue = <<>>
    /\ composer = <<>>
    /\ log = <<>>
    /\ pendingFile = <<>>
    /\ delivered = [id \in Prompts |-> 0]
    /\ screen = {}
    /\ everShown = {}
    /\ withdrawn = {}
    /\ restoredToComposer = {}
    /\ failedAccept = {}
    /\ notices = {}
    /\ turnOpen = FALSE
    /\ crashed = FALSE
    /\ inSession = TRUE
    /\ afterRestart = FALSE
    /\ submitted = {}
    /\ acceptedOrder = <<>>
    /\ crashes = 0
    /\ switches = 0
    /\ ambientTurns = 0
    /\ inFlight = NoInFlight
    /\ inFlightAccept = {}
    /\ inFlightWithdraw = {}
    /\ pendingRestoreWithdraw = <<>>
    /\ pendingRestoreComposer = <<>>

-----------------------------------------------------------------------------
(* Actions *)

(* An existing turn opens without consuming a queued prompt, so Submit can  *)
(* happen both while a turn is open and while no turn is open.              *)
OpenAmbientTurn ==
    /\ ~crashed
    /\ inSession
    /\ ~turnOpen
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ ambientTurns < 1
    /\ log' = Append(log, LogRec("start", "none", None))
    /\ turnOpen' = TRUE
    /\ ambientTurns' = ambientTurns + 1
    /\ UNCHANGED <<memQueue, composer, pendingFile, delivered, screen, everShown,
                   withdrawn, restoredToComposer, failedAccept, notices, crashed,
                   inSession, afterRestart, submitted, acceptedOrder, crashes,
                   switches, inFlight, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* An open turn commits and closes.                                         *)
CloseTurn ==
    /\ ~crashed
    /\ inSession
    /\ turnOpen
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ log' = Append(log, LogRec("commit", "none", None))
    /\ turnOpen' = FALSE
    /\ UNCHANGED <<memQueue, composer, pendingFile, delivered, screen, everShown,
                   withdrawn, restoredToComposer, failedAccept, notices, crashed,
                   inSession, afterRestart, submitted, acceptedOrder, crashes,
                   switches, ambientTurns, inFlight, inFlightAccept,
                   inFlightWithdraw, pendingRestoreWithdraw,
                   pendingRestoreComposer>>

(* User submits prompt id (allowed whether turnOpen is TRUE or FALSE).      *)
Submit(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ id \in Prompts \ submitted
    /\ submitted' = submitted \cup {id}
    /\ acceptedOrder' = Append(acceptedOrder, id)
    /\ memQueue' = Append(memQueue, id)
    /\ CASE Design = "current" ->
            /\ UNCHANGED <<log, pendingFile, inFlightAccept>>
         [] Design = "a" ->
            IF Mutant = "a_show_before_write"
              THEN /\ inFlightAccept' = inFlightAccept \cup {id}
                   /\ UNCHANGED <<log, pendingFile>>
              ELSE /\ log' = Append(log, LogRec("accepted", "none", id))
                   /\ UNCHANGED <<pendingFile, inFlightAccept>>
         [] Design = "a2" ->
            /\ log' = Append(log, LogRec("accepted", "none", id))
            /\ UNCHANGED <<pendingFile, inFlightAccept>>
         [] Design = "b" ->
            /\ pendingFile' = Append(pendingFile, id)
            /\ UNCHANGED <<log, inFlightAccept>>
    /\ UNCHANGED <<composer, delivered, screen, everShown, withdrawn,
                   restoredToComposer, failedAccept, notices, turnOpen, crashed,
                   inSession, afterRestart, crashes, switches, ambientTurns,
                   inFlight, inFlightWithdraw, pendingRestoreWithdraw,
                   pendingRestoreComposer>>

(* Design A2 fail-open admission (plan E8): record_accepted fails and       *)
(* returns null, so the prompt enters memQueue without a log record.        *)
SubmitFailAcceptWrite(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ Design = "a2"
    /\ id \in Prompts \ submitted
    /\ submitted' = submitted \cup {id}
    /\ acceptedOrder' = Append(acceptedOrder, id)
    /\ memQueue' = Append(memQueue, id)
    /\ failedAccept' = failedAccept \cup {id}
    /\ UNCHANGED <<composer, log, pendingFile, delivered, screen, everShown,
                   withdrawn, restoredToComposer, notices, turnOpen, crashed,
                   inSession, afterRestart, crashes, switches, ambientTurns,
                   inFlight, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Person submits restored composer text again as a new prompt with id.    *)
SubmitFromComposer(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ Design = "a2"
    /\ composer # <<>>
    /\ id \in Prompts \ submitted
    /\ composer' = <<>>
    /\ submitted' = submitted \cup {id}
    /\ acceptedOrder' = Append(acceptedOrder, id)
    /\ memQueue' = Append(memQueue, id)
    /\ log' = Append(log, LogRec("accepted", "none", id))
    /\ UNCHANGED <<pendingFile, delivered, screen, everShown, withdrawn,
                   restoredToComposer, failedAccept, notices, turnOpen, crashed,
                   inSession, afterRestart, crashes, switches, ambientTurns,
                   inFlight, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Mutant a_show_before_write completes its delayed accept-record write.    *)
FinishAcceptWrite(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ id \in inFlightAccept
    /\ log' = Append(log, LogRec("accepted", "none", id))
    /\ inFlightAccept' = inFlightAccept \ {id}
    /\ UNCHANGED <<memQueue, composer, pendingFile, delivered, screen, everShown,
                   withdrawn, restoredToComposer, failedAccept, notices, turnOpen,
                   crashed, inSession, afterRestart, submitted, acceptedOrder,
                   crashes, switches, ambientTurns, inFlight, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Screen shows the accepted row for id.                                    *)
ShowAccepted(id) ==
    /\ ~crashed
    /\ inSession
    /\ RestoreIdle
    /\ id \in MemIds
    /\ id \notin screen
    /\ CASE Design = "current" -> TRUE
         [] Design = "a"       -> (Mutant = "a_show_before_write" \/ HasAccepted(log, id))
         [] Design = "a2"      -> (HasAccepted(log, id) \/ id \in failedAccept)
         [] Design = "b"       -> InSeq(pendingFile, id)
    /\ screen' = screen \cup {id}
    /\ everShown' = everShown \cup {id}
    /\ UNCHANGED <<memQueue, composer, log, pendingFile, delivered, withdrawn,
                   restoredToComposer, failedAccept, notices, turnOpen, crashed,
                   inSession, afterRestart, submitted, acceptedOrder, crashes,
                   switches, ambientTurns, inFlight, inFlightAccept,
                   inFlightWithdraw, pendingRestoreWithdraw,
                   pendingRestoreComposer>>

(* Boundary step 1: deliver head of memQueue into an open turn.             *)
Boundary ==
    /\ ~crashed
    /\ inSession
    /\ turnOpen
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ memQueue # <<>>
    /\ LET id == Head(memQueue) IN
       /\ id \notin inFlightAccept
       /\ CASE Design = "current" ->
               /\ memQueue' = Tail(memQueue)
               /\ screen' = screen \ {id}
               /\ inFlight' = [kind |-> "cur_boundary", id |-> id]
               /\ UNCHANGED <<log, delivered>>
            [] Design = "a" ->
               IF Mutant = "a_two_lines"
                 THEN /\ log' = Append(log, LogRec("item", "steering", None))
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_line2", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE /\ log' = Append(log, LogRec("item", "carrier", id))
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
            [] Design = "a2" ->
               IF id \in failedAccept
                 THEN /\ log' = Append(log, LogRec("item", "steering", None))
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE IF Mutant = "a2_marker_later"
                 THEN /\ log' = Append(log, LogRec("item", "steering", None))
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a2_marker_later", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE /\ log' = log \o <<LogRec("item", "steering", None),
                                         LogRec("delivered", "none", id)>>
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
            [] Design = "b" ->
               /\ log' = Append(log, LogRec("item", "carrier", id))
               /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
               /\ inFlight' = [kind |-> "b_rewrite", id |-> id]
               /\ UNCHANGED <<memQueue, screen>>
    /\ UNCHANGED <<composer, pendingFile, everShown, withdrawn,
                   restoredToComposer, failedAccept, notices, turnOpen, crashed,
                   inSession, afterRestart, submitted, acceptedOrder, crashes,
                   switches, ambientTurns, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* TurnStarts step 1: open a turn with head of memQueue as its user prompt. *)
TurnStarts ==
    /\ ~crashed
    /\ inSession
    /\ ~turnOpen
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ memQueue # <<>>
    /\ LET id == Head(memQueue) IN
       /\ id \notin inFlightAccept
       /\ CASE Design = "current" ->
               /\ memQueue' = Tail(memQueue)
               /\ screen' = screen \ {id}
               /\ inFlight' = [kind |-> "cur_turn", id |-> id]
               /\ UNCHANGED <<log, delivered, turnOpen>>
            [] Design = "a" ->
               IF Mutant = "a_two_lines"
                 THEN /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "user", None)>>
                      /\ turnOpen' = TRUE
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_line2", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "carrier", id)>>
                      /\ turnOpen' = TRUE
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
            [] Design = "a2" ->
               IF id \in failedAccept
                 THEN /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "user", None)>>
                      /\ turnOpen' = TRUE
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE IF Mutant = "a2_marker_later"
                 THEN /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "user", None)>>
                      /\ turnOpen' = TRUE
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a2_marker_later", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
                 ELSE /\ log' = log \o <<LogRec("start", "none", None),
                                         LogRec("item", "user", None),
                                         LogRec("delivered", "none", id)>>
                      /\ turnOpen' = TRUE
                      /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
                      /\ inFlight' = [kind |-> "a_pop", id |-> id]
                      /\ UNCHANGED <<memQueue, screen>>
            [] Design = "b" ->
               /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "carrier", id)>>
               /\ turnOpen' = TRUE
               /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
               /\ inFlight' = [kind |-> "b_rewrite", id |-> id]
               /\ UNCHANGED <<memQueue, screen>>
    /\ UNCHANGED <<composer, pendingFile, everShown, withdrawn,
                   restoredToComposer, failedAccept, notices, crashed, inSession,
                   afterRestart, submitted, acceptedOrder, crashes, switches,
                   ambientTurns, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Step 2 of Boundary or TurnStarts.                                        *)
FinishDelivery ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind # "none"
    /\ LET id == inFlight.id IN
       CASE inFlight.kind = "cur_boundary" ->
            /\ log' = Append(log, LogRec("item", "steering", None))
            /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<memQueue, pendingFile, screen, turnOpen>>
         [] inFlight.kind = "cur_turn" ->
            /\ log' = log \o <<LogRec("start", "none", None), LogRec("item", "user", None)>>
            /\ turnOpen' = TRUE
            /\ delivered' = [delivered EXCEPT ![id] = @ + 1]
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<memQueue, pendingFile, screen>>
         [] inFlight.kind = "a_pop" ->
            /\ memQueue' = Tail(memQueue)
            /\ screen' = screen \ {id}
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<log, pendingFile, delivered, turnOpen>>
         [] inFlight.kind = "a_line2" ->
            /\ log' = Append(log, LogRec("item", "carrier_id", id))
            /\ memQueue' = Tail(memQueue)
            /\ screen' = screen \ {id}
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<pendingFile, delivered, turnOpen>>
         [] inFlight.kind = "a2_marker_later" ->
            /\ log' = Append(log, LogRec("delivered", "none", id))
            /\ memQueue' = Tail(memQueue)
            /\ screen' = screen \ {id}
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<pendingFile, delivered, turnOpen>>
         [] inFlight.kind = "b_rewrite" ->
            /\ pendingFile' = RemoveFromSeq(pendingFile, id)
            /\ memQueue' = Tail(memQueue)
            /\ screen' = screen \ {id}
            /\ inFlight' = NoInFlight
            /\ UNCHANGED <<log, delivered, turnOpen>>
    /\ UNCHANGED <<composer, everShown, withdrawn, restoredToComposer,
                   failedAccept, notices, crashed, inSession, afterRestart,
                   submitted, acceptedOrder, crashes, switches, ambientTurns,
                   inFlightAccept, inFlightWithdraw, pendingRestoreWithdraw,
                   pendingRestoreComposer>>

(* Person retracts queued prompt id.                                        *)
Withdraw(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ id \in MemIds
    /\ id \notin inFlightAccept
    /\ memQueue' = RemoveFromSeq(memQueue, id)
    /\ screen' = screen \ {id}
    /\ withdrawn' = withdrawn \cup {id}
    /\ CASE Design = "current" ->
            /\ UNCHANGED <<log, pendingFile, inFlightWithdraw>>
         [] Design = "a" ->
            IF Mutant = "a_withdraw_after_drop"
              THEN /\ inFlightWithdraw' = inFlightWithdraw \cup {id}
                   /\ UNCHANGED <<log, pendingFile>>
              ELSE /\ log' = Append(log, LogRec("withdrawn", "none", id))
                   /\ UNCHANGED <<pendingFile, inFlightWithdraw>>
         [] Design = "a2" ->
            IF id \in failedAccept
              THEN /\ UNCHANGED <<log, pendingFile, inFlightWithdraw>>
              ELSE /\ log' = Append(log, LogRec("withdrawn", "none", id))
                   /\ UNCHANGED <<pendingFile, inFlightWithdraw>>
         [] Design = "b" ->
            /\ pendingFile' = RemoveFromSeq(pendingFile, id)
            /\ UNCHANGED <<log, inFlightWithdraw>>
    /\ UNCHANGED <<composer, delivered, everShown, restoredToComposer,
                   failedAccept, notices, turnOpen, crashed, inSession,
                   afterRestart, submitted, acceptedOrder, crashes, switches,
                   ambientTurns, inFlight, inFlightAccept,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Mutant a_withdraw_after_drop writes its withdrawn record after RAM drop. *)
FinishWithdrawWrite(id) ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ id \in inFlightWithdraw
    /\ log' = Append(log, LogRec("withdrawn", "none", id))
    /\ inFlightWithdraw' = inFlightWithdraw \ {id}
    /\ UNCHANGED <<memQueue, composer, pendingFile, delivered, screen, everShown,
                   withdrawn, restoredToComposer, failedAccept, notices, turnOpen,
                   crashed, inSession, afterRestart, submitted, acceptedOrder,
                   crashes, switches, ambientTurns, inFlight, inFlightAccept,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* User switches away from this session to another session.                 *)
SessionSwitch ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ RestoreIdle
    /\ switches < MaxSwitches
    /\ inSession' = FALSE
    /\ afterRestart' = FALSE
    /\ switches' = switches + 1
    /\ turnOpen' = FALSE
    /\ log' = IF LogTurnOpen(log)
                THEN Append(log, LogRec("interrupt", "none", None))
                ELSE log
    /\ memQueue' = <<>>
    /\ composer' = <<>>
    /\ screen' = {}
    /\ notices' = CASE Design = "current" -> notices
                    [] Design = "a2"      -> notices \cup (MemIds \ failedAccept)
                    [] OTHER              -> notices \cup MemIds
    /\ inFlightAccept' = {}
    /\ inFlightWithdraw' = {}
    /\ UNCHANGED <<pendingFile, delivered, everShown, withdrawn,
                   restoredToComposer, failedAccept, crashed, submitted,
                   acceptedOrder, crashes, ambientTurns, inFlight,
                   pendingRestoreWithdraw, pendingRestoreComposer>>

(* Process crash (kill -9 / SIGHUP): RAM, composer, screen, notices, and    *)
(* in-flight steps are lost; log and pendingFile stay.                      *)
Crash ==
    /\ ~crashed
    /\ crashes < MaxCrashes
    /\ crashed' = TRUE
    /\ afterRestart' = FALSE
    /\ crashes' = crashes + 1
    /\ memQueue' = <<>>
    /\ composer' = <<>>
    /\ screen' = {}
    /\ notices' = {}
    /\ turnOpen' = FALSE
    /\ inFlight' = NoInFlight
    /\ inFlightAccept' = {}
    /\ inFlightWithdraw' = {}
    /\ pendingRestoreWithdraw' = <<>>
    /\ pendingRestoreComposer' = <<>>
    /\ UNCHANGED <<log, pendingFile, delivered, everShown, withdrawn,
                   restoredToComposer, failedAccept, inSession, submitted,
                   acceptedOrder, switches, ambientTurns>>

(* Restart after a crash (or resume of the modeled session).                *)
Reopen(isRestart) ==
    LET repaired == IF LogTurnOpen(log)
                      THEN Append(log, LogRec("interrupt", "none", None))
                      ELSE log
        restored == CASE Design = "current" -> <<>>
                      [] Design = "a"       -> RestoreA(repaired)
                      [] Design = "a2"      -> RestoreA2(repaired)
                      [] Design = "b"       -> RestoreB(repaired, pendingFile)
        withdrawRecs == [i \in 1..Len(restored) |-> LogRec("withdrawn", "none", restored[i])]
    IN /\ IF Design = "a2"
            THEN IF Mutant = "a2_withdraw_before_composer" /\ restored # <<>>
                   THEN /\ log' = repaired \o withdrawRecs
                        /\ memQueue' = <<>>
                        /\ composer' = <<>>
                        /\ pendingRestoreWithdraw' = <<>>
                        /\ pendingRestoreComposer' = restored
                   ELSE /\ log' = repaired
                        /\ memQueue' = <<>>
                        /\ composer' = restored
                        /\ pendingRestoreWithdraw' = restored
                        /\ pendingRestoreComposer' = <<>>
            ELSE /\ log' = repaired
                 /\ memQueue' = restored
                 /\ composer' = <<>>
                 /\ pendingRestoreWithdraw' = <<>>
                 /\ pendingRestoreComposer' = <<>>
       /\ pendingFile' = IF Design = "b" THEN restored ELSE pendingFile
       /\ notices' = Range(restored)
       /\ screen' = {}
       /\ turnOpen' = FALSE
       /\ crashed' = FALSE
       /\ inSession' = TRUE
       /\ afterRestart' = IF isRestart THEN TRUE ELSE afterRestart
       /\ UNCHANGED <<delivered, everShown, withdrawn, restoredToComposer,
                      failedAccept, submitted, acceptedOrder, crashes, switches,
                      ambientTurns, inFlight, inFlightAccept, inFlightWithdraw>>

Restart ==
    /\ crashed
    /\ Reopen(TRUE)

ResumeSession ==
    /\ ~crashed
    /\ ~inSession
    /\ Reopen(FALSE)

(* Step 2 of Design A2 restore: write input_withdrawn batch after composer   *)
(* already holds the restored prompts.                                      *)
FinishRestoreWithdraw ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ Design = "a2"
    /\ pendingRestoreWithdraw # <<>>
    /\ log' = log \o [i \in 1..Len(pendingRestoreWithdraw) |->
                        LogRec("withdrawn", "none", pendingRestoreWithdraw[i])]
    /\ restoredToComposer' = restoredToComposer \cup Range(pendingRestoreWithdraw)
    /\ pendingRestoreWithdraw' = <<>>
    /\ UNCHANGED <<memQueue, composer, pendingFile, delivered, screen, everShown,
                   withdrawn, failedAccept, notices, turnOpen, crashed, inSession,
                   afterRestart, submitted, acceptedOrder, crashes, switches,
                   ambientTurns, inFlight, inFlightAccept, inFlightWithdraw,
                   pendingRestoreComposer>>

(* Mutant a2_withdraw_before_composer puts text into composer after writing *)
(* withdrawn records.                                                       *)
FinishRestoreComposer ==
    /\ ~crashed
    /\ inSession
    /\ inFlight.kind = "none"
    /\ Design = "a2"
    /\ pendingRestoreComposer # <<>>
    /\ composer' = pendingRestoreComposer
    /\ restoredToComposer' = restoredToComposer \cup Range(pendingRestoreComposer)
    /\ pendingRestoreComposer' = <<>>
    /\ UNCHANGED <<memQueue, log, pendingFile, delivered, screen, everShown,
                   withdrawn, failedAccept, notices, turnOpen, crashed, inSession,
                   afterRestart, submitted, acceptedOrder, crashes, switches,
                   ambientTurns, inFlight, inFlightAccept, inFlightWithdraw,
                   pendingRestoreWithdraw>>

Next ==
    \/ OpenAmbientTurn
    \/ CloseTurn
    \/ \E id \in Prompts : Submit(id)
    \/ \E id \in Prompts : SubmitFailAcceptWrite(id)
    \/ \E id \in Prompts : SubmitFromComposer(id)
    \/ \E id \in Prompts : FinishAcceptWrite(id)
    \/ \E id \in Prompts : ShowAccepted(id)
    \/ Boundary
    \/ TurnStarts
    \/ FinishDelivery
    \/ \E id \in Prompts : Withdraw(id)
    \/ \E id \in Prompts : FinishWithdrawWrite(id)
    \/ SessionSwitch
    \/ Crash
    \/ Restart
    \/ ResumeSession
    \/ FinishRestoreWithdraw
    \/ FinishRestoreComposer

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

Pending(id) == id \in MemIds \/ id \in Range(composer)
Delivered(id) == delivered[id] > 0
Withdrawn(id) == id \in withdrawn

\* Every id ever shown as accepted is, at every state after a Restart,
\* delivered, withdrawn, pending (queued or in the composer), or already
\* restored to the composer and withdrawn from the log.
\* Prompts in failedAccept (fail open, plan E8) were admitted in memory with
\* input_id = null after record_accepted failed and therefore have no durable
\* log record; they are excluded here because they cannot survive a crash.
AcceptedSurvives ==
    afterRestart =>
        \A id \in everShown \ failedAccept :
            Delivered(id) \/ Withdrawn(id) \/ Pending(id) \/ (id \in restoredToComposer)

\* No prompt id is ever delivered more than once.
NeverDeliveredTwice ==
    \A id \in Prompts : delivered[id] <= 1

\* A prompt already delivered to a turn is never restored as pending (either
\* back into memQueue on restart or into the composer).
DeliveredNeverRestored ==
    \A id \in Prompts :
        delivered[id] > 0 =>
            /\ id \notin Range(composer)
            /\ id \notin restoredToComposer
            /\ (afterRestart /\ inFlight.kind = "none" => id \notin MemIds)

\* A withdrawn prompt is never delivered.
WithdrawnNeverDelivered ==
    \A id \in withdrawn : delivered[id] = 0

\* A withdrawn prompt stays gone from pending memory/composer and is never delivered.
WithdrawnStaysGone ==
    \A id \in withdrawn : id \notin MemIds /\ id \notin Range(composer) /\ delivered[id] = 0

SeqInAcceptedOrder(seq) ==
    /\ \A i, j \in 1..Len(seq) : i # j => seq[i] # seq[j]
    /\ \A i \in 1..Len(seq) : InSeq(acceptedOrder, seq[i])
    /\ \A i, j \in 1..Len(seq) :
         i < j => Pos(acceptedOrder, seq[i]) < Pos(acceptedOrder, seq[j])

\* Pending prompts in memQueue and restored prompts in composer always follow
\* their original admission order, with no duplicates.
RestoredInOrder ==
    /\ SeqInAcceptedOrder(memQueue)
    /\ SeqInAcceptedOrder(composer)

\* While the process is running, any accepted id (excluding fail-open E8
\* prompts that had no durable record) that is neither delivered, withdrawn,
\* nor pending has a user-visible notice or was already restored to composer.
NoSilentDrop ==
    ~crashed =>
        \A id \in everShown \ failedAccept :
            Delivered(id) \/ Withdrawn(id) \/ Pending(id) \/ (id \in notices) \/ (id \in restoredToComposer)

\* No item line appears outside an open turn; accepted, withdrawn, and
\* delivered marker records are not items.
ItemsInsideTurns ==
    \A i \in 1..Len(log) :
        log[i].kind = "item" => LogTurnOpen(SubSeq(log, 1, i - 1))

\* At most one turn is open at any point in the log.
AtMostOneOpenTurn ==
    CountKind(log, "start") - (CountKind(log, "commit") + CountKind(log, "interrupt")) \in {0, 1}
=============================================================================
