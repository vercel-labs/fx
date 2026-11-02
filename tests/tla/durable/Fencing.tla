------------------------------ MODULE Fencing ------------------------------
(***************************************************************************)
(* Step: one session, two processes.                                      *)
(*                                                                         *)
(* A laptop and a Vercel Function (or two functions) can both hold the    *)
(* same session: the laptop lid closes, the queue wakes a function, the   *)
(* lid opens again. The World's append is conditional on the writer's     *)
(* view of the log length (a compare-and-set on the next slot). A write   *)
(* that loses the race is rejected with a typed Fenced error and the      *)
(* process stops; it may reload the log and start again.                  *)
(*                                                                         *)
(* The session holds one pending call to a `replay: "never"` tool (for   *)
(* example send_email). Whoever wins the intent write runs it; anyone who *)
(* later finds an intent with no outcome writes "interrupted".           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Procs, MaxLen, MaxCrashes

VARIABLES
    log,          \* the World log: Seq of [by, kind]
    status,       \* [Procs -> "down" | "active" | "fenced"]
    view,         \* [Procs -> Nat]: log length the process loaded or wrote
    pc,           \* [Procs -> "idle" | "may_run" | "ran"]
    runs,         \* times the never tool's effect started
    actedFenced,  \* TRUE if a process that was not active ran the tool
    crashes

vars == <<log, status, view, pc, runs, actedFenced, crashes>>

Kinds == {"step", "intent", "result", "interrupted"}

Entry == [by : Procs, kind : Kinds]

HasKind(s, k) == \E i \in 1..Len(s) : s[i].kind = k

Resolved(s) == HasKind(s, "result") \/ HasKind(s, "interrupted")

\* What process p has seen of the log.
Known(p) == SubSeq(log, 1, view[p])

CountKind(k) == Len(SelectSeq(log, LAMBDA e : e.kind = k))

TypeOK ==
    /\ log \in Seq(Entry)
    /\ Len(log) <= MaxLen
    /\ status \in [Procs -> {"down", "active", "fenced"}]
    /\ view \in [Procs -> 0..MaxLen]
    /\ pc \in [Procs -> {"idle", "may_run", "ran"}]
    /\ runs \in 0..2
    /\ actedFenced \in BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ log = <<>>
    /\ status = [p \in Procs |-> "down"]
    /\ view = [p \in Procs |-> 0]
    /\ pc = [p \in Procs |-> "idle"]
    /\ runs = 0
    /\ actedFenced = FALSE
    /\ crashes = 0

\* Conditional append: it lands only if the log is still the length p saw.
\* Otherwise p is fenced and stops.
CasAppend(p, k, next) ==
    IF Len(log) = view[p]
    THEN /\ log' = Append(log, [by |-> p, kind |-> k])
         /\ view' = [view EXCEPT ![p] = @ + 1]
         /\ pc' = [pc EXCEPT ![p] = next]
         /\ UNCHANGED status
    ELSE /\ status' = [status EXCEPT ![p] = "fenced"]
         /\ UNCHANGED <<log, view, pc>>

\* A process opens the session: it folds the log it reads.
Load(p) ==
    /\ status[p] \in {"down", "fenced"}
    /\ status' = [status EXCEPT ![p] = "active"]
    /\ view' = [view EXCEPT ![p] = Len(log)]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ UNCHANGED <<log, runs, actedFenced, crashes>>

\* Ordinary progress (a lazy event such as a model response).
Step(p) ==
    /\ status[p] = "active"
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "step", pc[p])
    /\ UNCHANGED <<runs, actedFenced, crashes>>

\* The barrier before the never tool: write its intent.
Intent(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "idle"
    /\ ~HasKind(Known(p), "intent")
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "intent", "may_run")
    /\ UNCHANGED <<runs, actedFenced, crashes>>

\* The tool's effect starts.
Run(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "may_run"
    /\ runs < 2
    /\ runs' = runs + 1
    /\ actedFenced' = (actedFenced \/ status[p] # "active")
    /\ pc' = [pc EXCEPT ![p] = "ran"]
    /\ UNCHANGED <<log, status, view, crashes>>

\* The tool's result.
Result(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "ran"
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "result", "idle")
    /\ UNCHANGED <<runs, actedFenced, crashes>>

\* Restore found an intent with no outcome: the effect may have happened.
Recover(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "idle"
    /\ HasKind(Known(p), "intent")
    /\ ~Resolved(Known(p))
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "interrupted", "idle")
    /\ UNCHANGED <<runs, actedFenced, crashes>>

\* The process dies or the laptop sleeps for good.
Crash(p) ==
    /\ status[p] # "down"
    /\ crashes < MaxCrashes
    /\ status' = [status EXCEPT ![p] = "down"]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<log, view, runs, actedFenced>>

Next ==
    \E p \in Procs :
        \/ Load(p)
        \/ Step(p)
        \/ Intent(p)
        \/ Run(p)
        \/ Result(p)
        \/ Recover(p)
        \/ Crash(p)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* The never tool's effect starts at most once, across processes.
AtMostOneRun == runs <= 1

\* An effect only follows a durable intent.
RunHasDurableIntent == runs > 0 => HasKind(log, "intent")

\* One intent, and at most one outcome (result or interrupted).
OneIntent == CountKind("intent") <= 1
OneOutcome == CountKind("result") + CountKind("interrupted") <= 1

\* Every outcome follows the intent it resolves.
OutcomeFollowsIntent ==
    \A i \in 1..Len(log) :
        log[i].kind \in {"result", "interrupted"} =>
            \E j \in 1..(i - 1) : log[j].kind = "intent"

\* Only the process that won the intent can write its result.
ResultByRunner ==
    \A i, j \in 1..Len(log) :
        log[i].kind = "intent" /\ log[j].kind = "result" => log[i].by = log[j].by

\* A fenced or dead process never runs the tool.
FencedNeverActs == ~actedFenced

=============================================================================
