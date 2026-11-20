---------------------------- MODULE ShellEvalError ----------------------------
(***************************************************************************)
(* The error prefix that tests/e2e/ask-presentation.test.ts accepts for a  *)
(* user-profile command with an unclosed quote, against the login shells   *)
(* fx runs on.                                                             *)
(*                                                                         *)
(* fx runs such a command through a snapshot script that `eval`s it        *)
(* (`snapshotInvocation` and `snapshotScript` in                           *)
(* src/core/terminal/shell_resolver.zig), so each shell reports the quoting *)
(* error as an `eval` error under its own prefix:                          *)
(*                                                                         *)
(*   zsh      (eval):1: unmatched "                    evalLine1           *)
(*   bash 5   /dev/fd/0: eval: line 2: unexpected EOF  devFd0Eval          *)
(*   bash 3.2 /bin/bash: eval: line 7: unexpected EOF  bashEvalLine        *)
(*                                                                         *)
(* bash 5 sources the script from /dev/fd/0. bash 3.2 reads it with        *)
(* `eval "$(< /dev/fd/0)"`, so it names itself. The bash line number is    *)
(* abstracted away: tests/tla/drivers/shell_eval_error/ runs real shells   *)
(* with one-digit and two-digit numbers.                                   *)
(*                                                                         *)
(* A run is one login shell and one command: one with the quoting error,   *)
(* or a clean one. The test passes when its matcher                        *)
(* (tests/e2e/shell-eval-error.ts) accepts the quoting error. Accepted     *)
(* holds the line classes the matcher accepts.                             *)
(*                                                                         *)
(*   QuotingErrorAccepted  every supported shell's quoting error is        *)
(*                         accepted.                                       *)
(*   CleanLineRejected     a run without the error is not.                 *)
(*                                                                         *)
(* HeadAccepted is the rule before the fix: bash 3.2's line is rejected.   *)
(* AnyLineAccepted is a planted wrong rule: a clean run is accepted.       *)
(*                                                                         *)
(* TraceSpec replays runs the driver observed in real shells. A run        *)
(* advances only when the model agrees on the class of the line the shell  *)
(* printed and on the matcher's verdict. The replay is accepted when TLC   *)
(* violates the sentinel NotAllMatched, which is reachable only after      *)
(* every run matched.                                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Accepted,   \* the line classes the test's matcher accepts
    Observed    \* runs the driver saw, as [shell, kind, line, verdict]; NoRuns for a plain check

Shells == {"zsh", "bash32", "bash5"}
Kinds == {"error", "clean"}
Classes == {"evalLine1", "devFd0Eval", "bashEvalLine", "none"}

\* The class of the quoting-error line each shell prints.
Prefix == [zsh |-> "evalLine1", bash32 |-> "bashEvalLine", bash5 |-> "devFd0Eval"]

FixedAccepted == {"evalLine1", "devFd0Eval", "bashEvalLine"}
HeadAccepted == {"evalLine1", "devFd0Eval"}
AnyLineAccepted == Classes

NoRuns == << >>

VARIABLES shell, kind, line, verdict, n
vars == <<shell, kind, line, verdict, n>>

LineOf(s, k) == IF k = "error" THEN Prefix[s] ELSE "none"
Judge(l) == IF l \in Accepted THEN "pass" ELSE "fail"

Init ==
    /\ shell = "idle"
    /\ kind = "idle"
    /\ line = "idle"
    /\ verdict = "idle"
    /\ n = 0

Run(s, k) ==
    /\ shell' = s
    /\ kind' = k
    /\ line' = LineOf(s, k)
    /\ verdict' = Judge(LineOf(s, k))

Next == \E s \in Shells, k \in Kinds : Run(s, k) /\ UNCHANGED n

Spec == Init /\ [][Next]_vars

QuotingErrorAccepted == kind = "error" => verdict = "pass"
CleanLineRejected == kind = "clean" => verdict = "fail"

ReplayNext ==
    /\ n < Len(Observed)
    /\ LET o == Observed[n + 1]
       IN /\ Run(o.shell, o.kind)
          /\ o.line = line'
          /\ o.verdict = verdict'
    /\ n' = n + 1

TraceSpec == Init /\ [][ReplayNext]_vars

\* Violated exactly when a non-empty observation matched in full.
NotAllMatched == ~(Len(Observed) > 0 /\ n = Len(Observed))
=============================================================================
