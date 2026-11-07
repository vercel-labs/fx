---------------------------- MODULE StartupFixture ----------------------------
(***************************************************************************)
(* The fixture folder of benchmarks/startup.sh: the one folder under       *)
(* TMPDIR that a run makes its fixtures in and removes in its EXIT trap,   *)
(* next to folders that other runs or other programs made there.           *)
(*                                                                         *)
(* The rule: a run removes only a folder it created itself                 *)
(* (RemovesOnlyOwn), it runs the benchmarks inside a folder it created     *)
(* (WorksInOwn), and a run that ends by itself, or by a signal after its   *)
(* trap is set, leaves no folder of its own (LeavesNothing).               *)
(*                                                                         *)
(* Names are the folder names under TMPDIR the rule is about:              *)
(*   "pid"    fx-session-list-benchmark-<the run's PID>, the old path      *)
(*   "decoy"  a name of the mktemp pattern fx-session-list-benchmark.XXXXXX *)
(*            (the driver also uses it for any other fixture name that was *)
(*            there before the run)                                        *)
(*   "fresh"  another name of that pattern                                 *)
(* owner[n] is "none" when there is no folder n, "run" when this run made  *)
(* it, and "other" when someone else did. TMPDIR is usable when it takes   *)
(* new folders; a read-only or missing TMPDIR is not, though a read-only   *)
(* one can still hold folders of others.                                   *)
(*                                                                         *)
(* The script is the sequence Steps. The design (Bug = "none") is the      *)
(* script after the change: mktemp -d makes a new folder with a free name  *)
(* of the pattern, or fails, and with set -e the script exits before its   *)
(* trap line; the trap is set only after mktemp succeeds; then the checks  *)
(* for hyperfine and the fx binary, which may exit 1. A signal between     *)
(* mktemp and the trap line leaves the folder behind: a leak, never a      *)
(* removal. Bug = "today" is the script before the change: the PID path,   *)
(* the trap set before any folder exists, and mkdir -p, which reuses a     *)
(* folder that is already there. The other values plant one bug each;      *)
(* check.sh names the rule that must catch it.                             *)
(*                                                                         *)
(* Intrude is another program that makes a folder under TMPDIR at any      *)
(* time, such as one whose PID matches this run's. StartupFixtureTrace.tla *)
(* checks runs of the real script, recorded by                             *)
(* tests/tla/drivers/benchmarks/driver.ts, against these actions.          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Bug

Bugs == {"none", "today", "no_trap", "glob_cleanup", "reused_name", "mkdir_after_trap"}
Names == {"pid", "decoy", "fresh"}
Pattern == {"decoy", "fresh"}
Owners == {"none", "run", "other"}
Ends == {"none", "finished", "failed", "signal", "killed"}

Steps ==
    CASE Bug \in {"none", "glob_cleanup"} -> <<"mktemp", "trap", "check">>
      [] Bug = "no_trap"                  -> <<"mktemp", "check">>
      [] Bug = "reused_name"              -> <<"pick_pattern", "mkdir_p", "trap", "check">>
      [] Bug = "today"                    -> <<"pick_pid", "trap", "check", "mkdir_p">>
      [] Bug = "mkdir_after_trap"         -> <<"pick_pid", "trap", "mkdir", "check">>

VARIABLES
    pc,      \* the next step of Steps; Len(Steps) + 1 once the benchmarks run
    owner,   \* who made the folder of each name
    wiped,   \* folders of others that the run's cleanup removed or emptied
    root,    \* the name the run's cleanup removes; "" before it picks one
    armed,   \* the EXIT trap is set
    usable,  \* TMPDIR takes new folders
    ended,   \* how the run ended; "none" while it runs
    seen     \* <<the names in TMPDIR when hyperfine first ran>>, or <<>>

vars == <<pc, owner, wiped, root, armed, usable, ended, seen>>

Exists == {n \in Names : owner[n] # "none"}
Running == ended = "none"
Working == Running /\ pc = Len(Steps) + 1

Init ==
    /\ pc = 1
    /\ owner \in [Names -> {"none", "other"}]
    /\ wiped = {}
    /\ root = ""
    /\ armed = FALSE
    /\ usable \in BOOLEAN
    /\ ended = "none"
    /\ seen = <<>>

\* What cleanup removes: rm -rf "$SESSION_FIXTURE_ROOT", or every fixture
\* name for glob_cleanup.
Cleaned == IF Bug = "glob_cleanup" THEN Names ELSE {root} \cap Names

\* The script exits. Its EXIT trap runs when set, unless SIGKILL ended it.
\* rm -rf empties a folder of someone else's either way, and removes the
\* folder itself only when TMPDIR is usable.
End(e) ==
    /\ ended' = e
    /\ IF armed /\ e # "killed"
       THEN LET gone == {n \in Cleaned : owner[n] # "none"} IN
            /\ wiped' = wiped \cup {n \in gone : owner[n] = "other"}
            /\ owner' = [n \in Names |-> IF n \in gone /\ usable THEN "none" ELSE owner[n]]
       ELSE UNCHANGED <<wiped, owner>>
    /\ UNCHANGED <<pc, root, armed, usable, seen>>

On == pc' = pc + 1

\* mktemp -d: a new folder with a free name of the pattern, or a failure.
MakeTemp ==
    IF usable /\ \E n \in Pattern : owner[n] = "none"
    THEN \E n \in Pattern :
            /\ owner[n] = "none"
            /\ owner' = [owner EXCEPT ![n] = "run"]
            /\ root' = n
            /\ On
            /\ UNCHANGED <<wiped, armed, usable, ended, seen>>
    ELSE End("failed")

PickPid ==
    /\ root' = "pid"
    /\ On
    /\ UNCHANGED <<owner, wiped, armed, usable, ended, seen>>

\* reused_name: a name of the pattern, chosen without asking if it is free.
PickPattern ==
    /\ \E n \in Pattern : root' = n
    /\ On
    /\ UNCHANGED <<owner, wiped, armed, usable, ended, seen>>

\* mkdir -p: makes the folder, or reuses the one that is there.
MkdirP ==
    IF owner[root] # "none"
    THEN On /\ UNCHANGED <<owner, wiped, root, armed, usable, ended, seen>>
    ELSE IF usable
         THEN /\ owner' = [owner EXCEPT ![root] = "run"]
              /\ On
              /\ UNCHANGED <<wiped, root, armed, usable, ended, seen>>
         ELSE End("failed")

\* mkdir: fails when the folder is there.
Mkdir ==
    IF owner[root] = "none" /\ usable
    THEN /\ owner' = [owner EXCEPT ![root] = "run"]
         /\ On
         /\ UNCHANGED <<wiped, root, armed, usable, ended, seen>>
    ELSE End("failed")

Trap ==
    /\ armed' = TRUE
    /\ On
    /\ UNCHANGED <<owner, wiped, root, usable, ended, seen>>

\* The checks for hyperfine and the fx binary pass, or the script exits 1.
Check ==
    \/ On /\ UNCHANGED <<owner, wiped, root, armed, usable, ended, seen>>
    \/ End("failed")

Step ==
    /\ Running
    /\ pc <= Len(Steps)
    /\ CASE Steps[pc] = "mktemp"       -> MakeTemp
         [] Steps[pc] = "pick_pid"     -> PickPid
         [] Steps[pc] = "pick_pattern" -> PickPattern
         [] Steps[pc] = "mkdir_p"      -> MkdirP
         [] Steps[pc] = "mkdir"        -> Mkdir
         [] Steps[pc] = "trap"         -> Trap
         [] Steps[pc] = "check"        -> Check

\* hyperfine starts its first command, with HOME inside root.
Bench ==
    /\ Working
    /\ seen = <<>>
    /\ seen' = <<Exists>>
    /\ UNCHANGED <<pc, owner, wiped, root, armed, usable, ended>>

\* The benchmarks end: exit 0, or 1 when a benchmark or a budget fails.
Finish ==
    /\ Working
    /\ seen # <<>>
    /\ \E e \in {"finished", "failed"} : End(e)

\* SIGTERM or SIGINT: bash runs the EXIT trap. SIGKILL: nothing runs.
Signal == Running /\ End("signal")
Kill == Running /\ End("killed")

\* Another program makes a folder under TMPDIR.
Intrude ==
    /\ Running
    /\ usable
    /\ \E n \in Names :
          /\ owner[n] = "none"
          /\ owner' = [owner EXCEPT ![n] = "other"]
    /\ UNCHANGED <<pc, wiped, root, armed, usable, ended, seen>>

ScriptNext == Step \/ Bench \/ Finish \/ Signal \/ Kill
Next == ScriptNext \/ Intrude
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ Bug \in Bugs
    /\ pc \in 1..(Len(Steps) + 1)
    /\ owner \in [Names -> Owners]
    /\ wiped \subseteq Names
    /\ root \in Names \cup {""}
    /\ armed \in BOOLEAN
    /\ usable \in BOOLEAN
    /\ ended \in Ends
    /\ Len(seen) <= 1
    /\ \A i \in 1..Len(seen) : seen[i] \subseteq Names

\* A run never removes or empties a folder it did not create.
RemovesOnlyOwn == wiped = {}

\* The benchmarks run in a folder this run created.
WorksInOwn == Working => root \in Names /\ owner[root] = "run"

\* A run that ends by itself, or by a signal after its trap is set, leaves
\* no folder of its own behind.
LeavesNothing ==
    (ended \in {"finished", "failed"} \/ (ended = "signal" /\ armed))
        => \A n \in Names : owner[n] # "run"
=============================================================================
