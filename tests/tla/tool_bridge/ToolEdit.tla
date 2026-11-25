---------------------------- MODULE ToolEdit ----------------------------
(***************************************************************************)
(* How the file edits of a bash program reach fx, for the experimental    *)
(* bash tool. This is a design model: the code it describes has not       *)
(* landed.                                                                 *)
(*                                                                         *)
(* Design = "current": a program writes files itself, and fx sees only    *)
(*   its output.                                                           *)
(* Design = "bridge": a program can also ask fx to edit (`fx tool edit`)  *)
(*   through the tool bridge. fx prepares the edit against the file it    *)
(*   read, reviews that exact edit, applies it only if the file is still  *)
(*   the same, and records it for undo and the transcript. A program can  *)
(*   still write files itself.                                             *)
(* Design = "diff": a program writes files itself. When it ends, fx       *)
(*   compares the file with its version at the program's start and        *)
(*   reports the change.                                                   *)
(*                                                                         *)
(* Mutant plants one bug in "bridge"; "no_alive_check" is also how the    *)
(* MCP bridge treats a queued request of a gone program today. Class       *)
(* "nonideal" adds a write by another process, a killed program, and a    *)
(* review that is unavailable. fx learns that a program is gone only when *)
(* its socket hangs up, a step after the program ends (`seen`).           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS Design, Mutant, Class
ASSUME Design \in {"current", "bridge", "diff"}
ASSUME Mutant \in {"none", "no_recheck", "no_withdraw", "no_alive_check",
                   "apply_after_gone", "skip_review", "double_publish"}
ASSUME Class \in {"ideal", "nonideal"}

Ids == {1, 2}        \* edits a program asks fx for (design "bridge")
MaxRaw == 1          \* writes the program makes itself
MaxOther == 1        \* writes by another process (nonideal only)
MaxRows == 3

InFlight == {"sent", "prepared", "prompt", "allowed"}
Stages == InFlight \cup {"none", "denied", "applied", "stale", "dropped"}

VARIABLES
  prog,      \* "running" | "ended" | "killed"
  seen,      \* the bridge saw the program's socket hang up
  call,      \* "open" | "closed": the bash call's registration with the bridge
  history,   \* history[v] made file version v: "prog" | "other" | "fx"
  raw,       \* writes the program made itself
  other,     \* writes another process made
  req,       \* [Ids -> [stage, pre]]: pre is the version the edit was prepared on
  reviewed,  \* set of [id, pre]: an allow decision for that exact edit
  prompt,    \* the id whose approval prompt is open, or 0
  tracker,   \* undo entries [id, pre, post]; id 0 is a "diff" report
  rows,      \* ids shown in the transcript, in order; 0 is a "diff" report
  flags,     \* [stale, afterGone, askedAfterGone]: what fx did wrong
  diffDone   \* design "diff": the comparison ran

vars == <<prog, seen, call, history, raw, other, req, reviewed, prompt, tracker,
          rows, flags, diffDone>>

Disk == Len(history)

Init ==
  /\ prog = "running"
  /\ seen = FALSE
  /\ call = "open"
  /\ history = <<>>
  /\ raw = 0
  /\ other = 0
  /\ req = [i \in Ids |-> [stage |-> "none", pre |-> 0]]
  /\ reviewed = {}
  /\ prompt = 0
  /\ tracker = {}
  /\ rows = <<>>
  /\ flags = [stale |-> FALSE, afterGone |-> FALSE, askedAfterGone |-> FALSE]
  /\ diffDone = FALSE

SetStage(i, s) == req' = [req EXCEPT ![i].stage = s]

\* The program writes the file itself (sed, python3, a heredoc).
RawWrite ==
  /\ prog = "running"
  /\ raw < MaxRaw
  /\ history' = Append(history, "prog")
  /\ raw' = raw + 1
  /\ UNCHANGED <<prog, seen, call, other, req, reviewed, prompt, tracker, rows, flags, diffDone>>

\* Another process, such as a background job, writes the file.
OtherWrite ==
  /\ Class = "nonideal"
  /\ other < MaxOther
  /\ history' = Append(history, "other")
  /\ other' = other + 1
  /\ UNCHANGED <<prog, seen, call, raw, req, reviewed, prompt, tracker, rows, flags, diffDone>>

\* The program runs `edit` (`fx tool edit`) and waits for the answer.
Send(i) ==
  /\ Design = "bridge"
  /\ prog = "running"
  /\ req[i].stage = "none"
  /\ SetStage(i, "sent")
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, prompt, tracker, rows, flags, diffDone>>

\* fx reads the file and builds the edit against that version.
Prepare(i) ==
  /\ req[i].stage = "sent"
  /\ ~seen
  /\ req' = [req EXCEPT ![i] = [stage |-> "prepared", pre |-> Disk]]
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, prompt, tracker, rows, flags, diffDone>>

\* The edit is allowed without a prompt (configured rule, grant, or auto review).
AutoAllow(i) ==
  /\ req[i].stage = "prepared"
  /\ ~seen
  /\ SetStage(i, "allowed")
  /\ reviewed' = reviewed \cup {[id |-> i, pre |-> req[i].pre]}
  /\ UNCHANGED <<prog, seen, call, history, raw, other, prompt, tracker, rows, flags, diffDone>>

\* One approval prompt at a time, as the bridge does today.
Ask(i) ==
  /\ req[i].stage = "prepared"
  /\ prompt = 0
  /\ ~seen \/ Mutant = "no_alive_check"
  /\ SetStage(i, "prompt")
  /\ prompt' = i
  /\ flags' = [flags EXCEPT !.askedAfterGone = flags.askedAfterGone \/ seen]
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, tracker, rows, diffDone>>

\* An allow that comes after fx saw the program go starts nothing
\* (`mcp_call.zig`: "A late allow for the withdrawn prompt frees its slot").
UserAllow(i) ==
  /\ req[i].stage = "prompt"
  /\ prompt = i
  /\ SetStage(i, IF seen THEN "dropped" ELSE "allowed")
  /\ prompt' = 0
  /\ reviewed' = reviewed \cup {[id |-> i, pre |-> req[i].pre]}
  /\ UNCHANGED <<prog, seen, call, history, raw, other, tracker, rows, flags, diffDone>>

UserDeny(i) ==
  /\ req[i].stage = "prompt"
  /\ prompt = i
  /\ SetStage(i, "denied")
  /\ prompt' = 0
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, tracker, rows, flags, diffDone>>

\* A review that cannot complete denies (R4.2).
ReviewUnavailable(i) ==
  /\ Class = "nonideal"
  /\ req[i].stage = "prepared"
  /\ SetStage(i, "denied")
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, prompt, tracker, rows, flags, diffDone>>

\* Mutant: the edit runs with no review.
SkipReview(i) ==
  /\ Mutant = "skip_review"
  /\ req[i].stage = "prepared"
  /\ SetStage(i, "allowed")
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, prompt, tracker, rows, flags, diffDone>>

\* fx applies the edit only while its program waits, and only on the version
\* it prepared; otherwise it answers that the file changed.
Apply(i) ==
  /\ req[i].stage = "allowed"
  /\ ~seen \/ Mutant = "apply_after_gone"
  /\ IF Disk = req[i].pre \/ Mutant = "no_recheck"
     THEN /\ history' = Append(history, "fx")
          /\ tracker' = tracker \cup {[id |-> i, pre |-> Disk, post |-> Disk + 1]}
          /\ SetStage(i, "applied")
          /\ flags' = [flags EXCEPT !.stale = flags.stale \/ Disk # req[i].pre,
                                    !.afterGone = flags.afterGone \/ seen]
     ELSE /\ SetStage(i, "stale")
          /\ UNCHANGED <<history, tracker, flags>>
  /\ UNCHANGED <<prog, seen, call, raw, other, reviewed, prompt, rows, diffDone>>

\* fx records the applied edit in the transcript, once.
Publish(i) ==
  /\ req[i].stage = "applied"
  /\ Len(rows) < MaxRows
  /\ (\A k \in 1..Len(rows) : rows[k] # i) \/ Mutant = "double_publish"
  /\ rows' = Append(rows, i)
  /\ UNCHANGED <<prog, seen, call, history, raw, other, req, reviewed, prompt, tracker, flags, diffDone>>

\* The program ends on its own once it has its answers.
End ==
  /\ prog = "running"
  /\ \A i \in Ids : req[i].stage \notin InFlight
  /\ prog' = "ended"
  /\ UNCHANGED <<seen, call, history, raw, other, req, reviewed, prompt, tracker, rows, flags, diffDone>>

Kill ==
  /\ Class = "nonideal"
  /\ prog = "running"
  /\ prog' = "killed"
  /\ UNCHANGED <<seen, call, history, raw, other, req, reviewed, prompt, tracker, rows, flags, diffDone>>

\* The bridge sees the program's socket hang up.
Hangup ==
  /\ prog # "running"
  /\ ~seen
  /\ seen' = TRUE
  /\ UNCHANGED <<prog, call, history, raw, other, req, reviewed, prompt, tracker, rows, flags, diffDone>>

\* When its program is gone, fx withdraws the program's open requests. An
\* open prompt stays until the person answers it, and its answer then runs
\* nothing: the MCP bridge's recorded rule (`mcp_call_bridge.zig` logs "its
\* permission prompt stays until answered, and nothing runs").
Withdraw(i) ==
  /\ seen
  /\ Mutant # "no_withdraw"
  /\ req[i].stage \in InFlight \ {"prompt"}
  /\ SetStage(i, "dropped")
  /\ UNCHANGED prompt
  /\ UNCHANGED <<prog, seen, call, history, raw, other, reviewed, tracker, rows, flags, diffDone>>

\* The bash call unregisters once nothing of its program is in flight.
Close ==
  /\ call = "open"
  /\ seen
  /\ \A i \in Ids : req[i].stage \notin InFlight
  /\ call' = "closed"
  /\ UNCHANGED <<prog, seen, history, raw, other, req, reviewed, prompt, tracker, rows, flags, diffDone>>

\* Design "diff": compare the file with its version when the program started.
DiffReport ==
  /\ Design = "diff"
  /\ prog # "running"
  /\ ~diffDone
  /\ diffDone' = TRUE
  /\ IF Disk # 0
     THEN /\ tracker' = tracker \cup {[id |-> 0, pre |-> 0, post |-> Disk]}
          /\ rows' = Append(rows, 0)
     ELSE UNCHANGED <<tracker, rows>>
  /\ UNCHANGED <<prog, seen, call, history, raw, other, req, reviewed, prompt, flags>>

Next ==
  \/ RawWrite \/ OtherWrite \/ End \/ Kill \/ Hangup \/ Close \/ DiffReport
  \/ \E i \in Ids :
       \/ Send(i) \/ Prepare(i) \/ AutoAllow(i) \/ Ask(i) \/ UserAllow(i)
       \/ UserDeny(i) \/ ReviewUnavailable(i) \/ SkipReview(i) \/ Apply(i)
       \/ Publish(i) \/ Withdraw(i)

\* fx's own steps are fair; the person may never answer a prompt.
Fairness ==
  /\ WF_vars(Hangup)
  /\ WF_vars(Close)
  /\ WF_vars(DiffReport)
  /\ \A i \in Ids : WF_vars(Prepare(i)) /\ WF_vars(Withdraw(i)) /\ WF_vars(Publish(i))

\* A person answers an open prompt in time.
Answers == \A i \in Ids : WF_vars(UserAllow(i) \/ UserDeny(i))

Spec == Init /\ [][Next]_vars /\ Fairness /\ Answers

\* No answer ever comes: shows that teardown waits for the person.
SpecNoAnswer == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
  /\ prog \in {"running", "ended", "killed"}
  /\ call \in {"open", "closed"}
  /\ \A i \in Ids : req[i].stage \in Stages
  /\ prompt \in Ids \cup {0}

-----------------------------------------------------------------------------
(* Requirements *)

\* Every change fx shows as an edit was reviewed as that exact edit (R4.1, R4.2).
ExactReview ==
  \A e \in tracker : e.id # 0 /\ [id |-> e.id, pre |-> req[e.id].pre] \in reviewed

\* fx never writes over a version it did not show.
NoStaleApply == ~flags.stale

\* fx never edits for a program that is gone.
NoApplyAfterGone == ~flags.afterGone

\* fx opens no approval prompt for a program it knows is gone.
NoAskAfterGone == ~flags.askedAfterGone

\* An open prompt is withdrawn once its program is gone.
PromptsEnd == (prompt # 0 /\ prog # "running") ~> prompt = 0

\* Each edit appears in the transcript once.
ShownOnce == \A j, k \in 1..Len(rows) : j # k => rows[j] # rows[k]

\* What fx reports as the program's change, the program made.
HonestReport ==
  \A e \in tracker : e.id = 0 => \A v \in 1..e.post : history[v] = "prog"

\* Once the program is done, a change it made itself is visible.
RawEditsVisible ==
  (prog # "running" /\ (Design = "diff" => diffDone)) =>
    (raw > 0 => \E e \in tracker : e.id = 0)

\* Every edit fx applies reaches the transcript.
AppliedShown ==
  \A i \in Ids : req[i].stage = "applied" ~> \E k \in 1..Len(rows) : rows[k] = i

\* Witnesses that the bridge design is not vacuous: each must be violated.
NeverApplied == \A i \in Ids : req[i].stage # "applied"
NeverPrompted == prompt = 0
NeverStale == \A i \in Ids : req[i].stage # "stale"

\* The bash call always finishes after its program is gone.
TeardownEnds == prog # "running" ~> call = "closed"
=============================================================================
