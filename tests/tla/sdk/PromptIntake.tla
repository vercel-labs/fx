----------------------------- MODULE PromptIntake -----------------------------
(***************************************************************************)
(* How one durable session object takes prompts in, from `prompt()` to the *)
(* session log, and how the worker runs what the log holds.                *)
(*                                                                         *)
(* A prompt is text, which needs nothing before it is stored, or carries   *)
(* images, which are prepared first: each image goes to the session's      *)
(* image store, which the log then names. A prompt made while an earlier   *)
(* image prompt from the same session object is not yet stored waits for   *)
(* it, then prepares its own images; with Gate = FALSE it does not wait    *)
(* (PromptIntake-NoGate.cfg). Once ready, a prompt whose agent closed      *)
(* meanwhile is refused; with CloseCheck = FALSE it is stored anyway       *)
(* (PromptIntake-NoCloseCheck.cfg). The wait ends when the earlier prompt  *)
(* is stored or fails; with GateReleasesOnFailure = FALSE a failure holds  *)
(* every prompt behind it forever (PromptIntake-GateHeldOnFailure.cfg, a   *)
(* deadlock).                                                              *)
(*                                                                         *)
(* A prompt's signal may have aborted before the call, and then nothing is *)
(* stored, or abort later. Until the prompt's send begins, an abort        *)
(* withdraws it: nothing is stored and no cancel goes out; with            *)
(* AbortWithdraws = FALSE the prompt goes on, and a cancel naming it goes  *)
(* out at once (PromptIntake-NoWithdraw.cfg). Once its send has begun, an  *)
(* abort sends a cancel naming the prompt, and the cancel and the prompt   *)
(* land in the log in either order. Preparing (an image write) or a log    *)
(* write may fail, up to MaxFaults times.                                  *)
(*                                                                         *)
(* The worker runs the log's prompts one at a time, in log order. It ends  *)
(* a prompt whose cancel landed without running it, and cancels a running  *)
(* one when its cancel lands. After the agent closes, a worker still       *)
(* running goes on until the log holds nothing more for it; no new one     *)
(* starts.                                                                 *)
(*                                                                         *)
(* `act` names each step and its prompt, so                                *)
(* tests/tla/drivers/drive-intake.mjs can replay any path of the state graph *)
(* against the real code.                                                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    N,                     \* prompts the caller makes, at most
    MaxFaults,             \* bound on failed preparations and failed log writes
    Gate,                  \* whether a prompt waits for earlier image prompts
    CloseCheck,            \* whether a prompt ready after close is refused
    GateReleasesOnFailure, \* whether a failed prompt lets later ones go
    AbortWithdraws         \* whether an abort before the send withdraws the prompt

ASSUME N \in Nat /\ MaxFaults \in Nat
ASSUME Gate \in BOOLEAN /\ CloseCheck \in BOOLEAN /\ GateReleasesOnFailure \in BOOLEAN /\ AbortWithdraws \in BOOLEAN

Prompts == 1..N
Kinds == {"text", "image"}
Phases == {"unmade", "early", "preparing", "sending", "stored", "failed", "refused", "withdrawn"}

VARIABLES
    made,        \* how many prompts the caller has made
    kind,        \* each prompt: text, or images to prepare
    early,       \* whether its signal had aborted before the call
    before,      \* the earlier image prompt it waits for, or 0
    ph,          \* where it is on its way into the log
    acc,         \* its `accepted`: pending, resolved or rejected
    res,         \* its `result`: pending, end, cancelled or rejected
    aborted,     \* whether its signal aborted after the call
    cancel,      \* its cancel: none, held on its way, or stored
    log,         \* the prompts the log holds, in the order they landed
    ran,         \* whether the worker started its turn
    open,        \* the prompt whose turn runs now, or 0
    done,        \* the prompts whose turns ended
    active,      \* whether a worker runs the session now
    closed,      \* whether the agent closed
    faults,      \* failures so far
    prepAtClose, \* the prompts still preparing when the agent closed
    act          \* the step that led here

vars == <<made, kind, early, before, ph, acc, res, aborted, cancel, log, ran, open, done,
          active, closed, faults, prepAtClose, act>>

None == "none"
Act(name, p) == [name |-> name, p |-> p, kind |-> None, early |-> FALSE]

TypeOK ==
    /\ made \in 0..N
    /\ kind \in [Prompts -> Kinds \cup {None}]
    /\ early \in [Prompts -> BOOLEAN]
    /\ before \in [Prompts -> 0..N]
    /\ ph \in [Prompts -> Phases]
    /\ acc \in [Prompts -> {"pending", "resolved", "rejected"}]
    /\ res \in [Prompts -> {"pending", "end", "cancelled", "rejected"}]
    /\ aborted \in [Prompts -> BOOLEAN]
    /\ cancel \in [Prompts -> {"none", "held", "stored"}]
    /\ log \in Seq(Prompts)
    /\ ran \in [Prompts -> BOOLEAN]
    /\ open \in 0..N
    /\ done \subseteq Prompts
    /\ active \in BOOLEAN
    /\ closed \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ prepAtClose \subseteq Prompts
    /\ act \in [name: {"Init", "Make", "Released", "Prepared", "PrepareFail", "Store", "StoreFail",
                       "Abort", "CancelStore", "Close", "Start", "Skip", "CancelRun", "End", "Finished"},
                p: 0..N, kind: Kinds \cup {None}, early: BOOLEAN]

Init ==
    /\ made = 0
    /\ kind = [i \in Prompts |-> None]
    /\ early = [i \in Prompts |-> FALSE]
    /\ before = [i \in Prompts |-> 0]
    /\ ph = [i \in Prompts |-> "unmade"]
    /\ acc = [i \in Prompts |-> "pending"]
    /\ res = [i \in Prompts |-> "pending"]
    /\ aborted = [i \in Prompts |-> FALSE]
    /\ cancel = [i \in Prompts |-> "none"]
    /\ log = <<>>
    /\ ran = [i \in Prompts |-> FALSE]
    /\ open = 0
    /\ done = {}
    /\ active = FALSE
    /\ closed = FALSE
    /\ faults = 0
    /\ prepAtClose = {}
    /\ act = Act("Init", 0)

Stored == {log[k] : k \in 1..Len(log)}
Pending(d) == SelectSeq(log, LAMBDA i : i \notin d)

\* The latest image prompt not yet stored or failed: what a new prompt waits
\* for. Every earlier image prompt is settled once it is, since it waited.
Waiting == {j \in 1..made : kind[j] = "image" /\ ~early[j] /\ acc[j] = "pending"}
GateNow == IF Gate /\ Waiting # {} THEN CHOOSE j \in Waiting : \A k \in Waiting : k <= j ELSE 0

\* Whether the prompt i waits for lets it go: it and every image prompt
\* before it have settled, since one withdrawn while it waited settles
\* before the prompts it waited for.
Ready(i) ==
    IF before[i] = 0 THEN TRUE
    ELSE IF GateReleasesOnFailure
         THEN \A j \in 1..before[i] : (kind[j] = "image" /\ ~early[j]) => acc[j] # "pending"
         ELSE acc[before[i]] = "resolved"

\* A prompt that cannot be stored: both of its promises reject.
Reject(i, phase) ==
    /\ ph' = [ph EXCEPT ![i] = phase]
    /\ acc' = [acc EXCEPT ![i] = "rejected"]
    /\ res' = [res EXCEPT ![i] = "rejected"]

Make(i, k, e) ==
    /\ ~closed
    /\ made = i - 1
    /\ made' = i
    /\ kind' = [kind EXCEPT ![i] = k]
    /\ early' = [early EXCEPT ![i] = e]
    /\ IF e
         THEN /\ ph' = [ph EXCEPT ![i] = "early"]
              /\ acc' = [acc EXCEPT ![i] = "resolved"]
              /\ res' = [res EXCEPT ![i] = "cancelled"]
              /\ UNCHANGED before
         ELSE /\ before' = [before EXCEPT ![i] = GateNow]
              /\ ph' = [ph EXCEPT ![i] = IF k = "text" /\ GateNow = 0 THEN "sending" ELSE "preparing"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = [name |-> "Make", p |-> i, kind |-> k, early |-> e]
    /\ UNCHANGED <<aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>

\* A text prompt that waited goes on once the earlier prompt lets it.
Released(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "text" /\ Ready(i)
    /\ IF closed /\ CloseCheck
         THEN Reject(i, "refused")
         ELSE /\ ph' = [ph EXCEPT ![i] = "sending"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = Act("Released", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>

Prepared(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "image" /\ Ready(i)
    /\ IF closed /\ CloseCheck
         THEN Reject(i, "refused")
         ELSE /\ ph' = [ph EXCEPT ![i] = "sending"]
              /\ UNCHANGED <<acc, res>>
    /\ act' = Act("Prepared", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, faults, prepAtClose>>

PrepareFail(i) ==
    /\ ph[i] = "preparing" /\ kind[i] = "image" /\ Ready(i)
    /\ faults < MaxFaults
    /\ Reject(i, "failed")
    /\ faults' = faults + 1
    /\ act' = Act("PrepareFail", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, prepAtClose>>

Store(i) ==
    /\ ph[i] = "sending"
    /\ log' = Append(log, i)
    /\ ph' = [ph EXCEPT ![i] = "stored"]
    /\ acc' = [acc EXCEPT ![i] = "resolved"]
    /\ act' = Act("Store", i)
    /\ UNCHANGED <<made, kind, early, before, res, aborted, cancel, ran, open, done, active, closed, faults, prepAtClose>>

StoreFail(i) ==
    /\ ph[i] = "sending"
    /\ faults < MaxFaults
    /\ Reject(i, "failed")
    /\ faults' = faults + 1
    /\ act' = Act("StoreFail", i)
    /\ UNCHANGED <<made, kind, early, before, aborted, cancel, log, ran, open, done, active, closed, prepAtClose>>

\* The signal aborts while the prompt's result is still pending. Before the
\* prompt's send begins, it is withdrawn: never stored, its `accepted`
\* resolved and its result cancelled, and no cancel goes out. Once the send
\* has begun, or the prompt is stored, a cancel naming it goes out.
Abort(i) ==
    /\ ph[i] \notin {"unmade", "early"}
    /\ ~aborted[i] /\ res[i] = "pending"
    /\ aborted' = [aborted EXCEPT ![i] = TRUE]
    /\ IF ph[i] = "preparing" /\ AbortWithdraws
         THEN /\ ph' = [ph EXCEPT ![i] = "withdrawn"]
              /\ acc' = [acc EXCEPT ![i] = "resolved"]
              /\ res' = [res EXCEPT ![i] = "cancelled"]
              /\ UNCHANGED cancel
         ELSE /\ cancel' = [cancel EXCEPT ![i] = "held"]
              /\ UNCHANGED <<ph, acc, res>>
    /\ act' = Act("Abort", i)
    /\ UNCHANGED <<made, kind, early, before, log, ran, open, done, active, closed, faults, prepAtClose>>

CancelStore(i) ==
    /\ cancel[i] = "held"
    /\ cancel' = [cancel EXCEPT ![i] = "stored"]
    /\ act' = Act("CancelStore", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, log, ran, open, done, active, closed, faults, prepAtClose>>

Close ==
    /\ ~closed
    /\ closed' = TRUE
    /\ prepAtClose' = {i \in Prompts : ph[i] = "preparing"}
    /\ act' = Act("Close", 0)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, cancel, log, ran, open, done, active, faults>>

\* The worker. A new one starts only while the agent is open.
CanRun == open = 0 /\ (~closed \/ active) /\ Pending(done) # <<>>

Start(i) ==
    /\ CanRun /\ Head(Pending(done)) = i /\ cancel[i] # "stored"
    /\ open' = i
    /\ ran' = [ran EXCEPT ![i] = TRUE]
    /\ active' = TRUE
    /\ act' = Act("Start", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, res, aborted, cancel, log, done, closed, faults, prepAtClose>>

\* A turn ends; the worker goes on while the log holds more for it.
Ended(i, how) ==
    /\ done' = done \cup {i}
    /\ res' = [res EXCEPT ![i] = how]
    /\ active' = (Pending(done \cup {i}) # <<>>)

Skip(i) ==
    /\ CanRun /\ Head(Pending(done)) = i /\ cancel[i] = "stored"
    /\ Ended(i, "cancelled")
    /\ act' = Act("Skip", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, open, closed, faults, prepAtClose>>

CancelRun(i) ==
    /\ open = i /\ i # 0 /\ cancel[i] = "stored"
    /\ open' = 0
    /\ Ended(i, "cancelled")
    /\ act' = Act("CancelRun", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, closed, faults, prepAtClose>>

End(i) ==
    /\ open = i /\ i # 0 /\ cancel[i] # "stored"
    /\ open' = 0
    /\ Ended(i, "end")
    /\ act' = Act("End", i)
    /\ UNCHANGED <<made, kind, early, before, ph, acc, aborted, cancel, log, ran, closed, faults, prepAtClose>>

\* Every prompt made has been stored or refused: the run may stop here.
Settled == \A i \in 1..made : acc[i] # "pending"
Finished == Settled /\ UNCHANGED vars

Next ==
    \/ \E i \in Prompts, k \in Kinds, e \in BOOLEAN : Make(i, k, e)
    \/ \E i \in Prompts :
         \/ Released(i) \/ Prepared(i) \/ PrepareFail(i) \/ Store(i) \/ StoreFail(i)
         \/ Abort(i) \/ CancelStore(i) \/ Start(i) \/ Skip(i) \/ CancelRun(i) \/ End(i)
    \/ Close
    \/ Finished

Spec == Init /\ [][Next]_vars

\* The paths a driver can take. The code makes each of these steps on its
\* own as soon as it can, and a driver acts only once the code has settled,
\* so here the caller and the faults move only when none of them can.
Auto == \E i \in Prompts : Released(i) \/ Start(i) \/ Skip(i) \/ CancelRun(i)
Quiet == ~ENABLED Auto
DriverStep ==
    \/ \E i \in Prompts, k \in Kinds, e \in BOOLEAN : Make(i, k, e)
    \/ \E i \in Prompts :
         Prepared(i) \/ PrepareFail(i) \/ Store(i) \/ StoreFail(i) \/ Abort(i) \/ CancelStore(i) \/ End(i)
    \/ Close
DriveSpec == Init /\ [][(Quiet /\ DriverStep) \/ Auto \/ Finished]_vars

(***************************************************************************)
(* Invariants.                                                             *)
(***************************************************************************)

\* A prompt made after an image prompt is never stored before it.
ImageOrder ==
    \A a, b \in 1..Len(log) : a < b => ~(log[b] < log[a] /\ kind[log[b]] = "image")

\* `accepted` resolves exactly when the prompt is stored, or for a prompt
\* whose signal aborted before its send began, which is never stored.
StoredIffAccepted ==
    \A i \in 1..made : (acc[i] = "resolved") <=> (i \in Stored \/ ph[i] \in {"early", "withdrawn"})

\* A cancel goes out only for a prompt whose send has begun: one that is
\* on its way, stored, or whose store failed.
CancelOnlyWhenSent == \A i \in Prompts : cancel[i] # "none" => ph[i] \in {"sending", "stored", "failed"}

\* A withdrawn prompt leaves nothing in the log.
WithdrawnNeverStored == \A i \in Prompts : ph[i] = "withdrawn" => i \notin Stored /\ cancel[i] = "none"

NeverStoredTwice == \A a, b \in 1..Len(log) : a # b => log[a] # log[b]

\* A prompt still preparing when the agent closed is never stored.
ClosedStopsPreparing == prepAtClose \cap Stored = {}

\* Only a prompt's own signal cancels it.
CancelledOnlyOwn == \A i \in Prompts : res[i] = "cancelled" => (aborted[i] \/ early[i])

\* A prompt that could not be stored never runs.
NoRunAfterRejected == \A i \in Prompts : ran[i] => acc[i] = "resolved"

\* One turn at a time, each for a prompt the log holds.
RunsStored == open # 0 => (open \in Stored /\ open \notin done)
=============================================================================
