----------------------------- MODULE CliHangup -----------------------------
(***************************************************************************)
(* CLI command terminal hang-up vs real I/O error classification.          *)
(*                                                                         *)
(* Models CLI commands (`fx ask`, `fx replay`, `fx status`, `fx login`,    *)
(* `fx setup`, `fx teams`) across:                                         *)
(*   - `design-a`: classify at every read/write boundary via shared        *)
(*     `terminalGone`, propagate `TerminalHungUp` through subcommand       *)
(*     catch blocks, and exit quietly with 129 (`128 + SIGHUP`) at         *)
(*     `app_entry_runtime.commandFailure`.                                 *)
(*   - `design-b`: classify only at `commandFailure` without boundary      *)
(*     checks or catch rethrows (violates GoneIsQuiet on catch/hang/erase).*)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Design,  \* "current" | "design-a" | "design-b"
          Mutant,  \* "none" | "swallow_catch" | "erase_eio" | "blind_eio" | "ignore_hup_eof"
          Class    \* "all" | "ideal" | "nonideal"

VARIABLES termState,     \* "open" | "hung_up"
          phase,         \* "write_io" | "stdin_prompt" | "subcmd_catch" | "exit_handler" | "done"
          errKind,       \* "none" | "eio_tty" | "eof_hup" | "eio_file" | "TerminalHungUp" | "OutputWriteFailed" | "SwallowedMsg"
          errOnOpenTerm, \* BOOLEAN
          hasCatch,      \* BOOLEAN: command runs inside a subcommand catch block (setup, teams, ask --json)
          outcome,       \* "running" | "quiet_129" | "error_1" | "hung"
          msgPrinted     \* "none" | "disk" | "write_failed" | "swallowed" | "file_err"

vars == <<termState, phase, errKind, errOnOpenTerm, hasCatch, outcome, msgPrinted>>

TypeOK ==
  /\ termState \in {"open", "hung_up"}
  /\ phase \in {"write_io", "stdin_prompt", "subcmd_catch", "exit_handler", "done"}
  /\ errKind \in {"none", "eio_tty", "eof_hup", "eio_file", "TerminalHungUp", "OutputWriteFailed", "SwallowedMsg"}
  /\ errOnOpenTerm \in BOOLEAN
  /\ hasCatch \in BOOLEAN
  /\ outcome \in {"running", "ok_0", "quiet_129", "error_1", "hung"}
  /\ msgPrinted \in {"none", "disk", "write_failed", "swallowed", "file_err"}

Init ==
  /\ termState = "open"
  /\ phase \in {"write_io", "stdin_prompt"}
  /\ errKind = "none"
  /\ errOnOpenTerm = FALSE
  /\ hasCatch \in (IF Class = "ideal" THEN {FALSE} ELSE BOOLEAN)
  /\ outcome = "running"
  /\ msgPrinted = "none"

Running == outcome = "running" /\ phase /= "done"

TerminalClose ==
  /\ Running
  /\ termState = "open"
  /\ termState' = "hung_up"
  /\ UNCHANGED <<phase, errKind, errOnOpenTerm, hasCatch, outcome, msgPrinted>>

WriteTtyFail ==
  /\ Running
  /\ phase = "write_io"
  /\ errKind = "none"
  /\ IF termState = "hung_up"
     THEN /\ errOnOpenTerm' = FALSE
          /\ IF Design = "design-a"
             THEN IF Mutant = "erase_eio"
                  THEN errKind' = "OutputWriteFailed"
                  ELSE errKind' = "TerminalHungUp"
             ELSE IF Design = "design-b"
                  THEN errKind' = "OutputWriteFailed"
                  ELSE errKind' = "eio_tty"
          /\ phase' = IF hasCatch THEN "subcmd_catch" ELSE "exit_handler"
     ELSE /\ Class /= "ideal"
          /\ errOnOpenTerm' = TRUE
          /\ errKind' = (IF Design = "design-a" /\ Mutant = "blind_eio" THEN "TerminalHungUp" ELSE "eio_tty")
          /\ phase' = IF hasCatch THEN "subcmd_catch" ELSE "exit_handler"
  /\ UNCHANGED <<termState, hasCatch, outcome, msgPrinted>>

ReadStdinHangup ==
  /\ Running
  /\ phase = "stdin_prompt"
  /\ termState = "hung_up"
  /\ errKind = "none"
  /\ errOnOpenTerm' = FALSE
  /\ LET sawHup == (Design = "design-a" /\ Mutant /= "ignore_hup_eof")
     IN IF sawHup
        THEN /\ errKind' = "TerminalHungUp"
             /\ phase' = IF hasCatch THEN "subcmd_catch" ELSE "exit_handler"
             /\ outcome' = "running"
        ELSE IF Design = "current"
             THEN /\ errKind' = (IF hasCatch THEN "SwallowedMsg" ELSE "none")
                  /\ phase' = IF hasCatch THEN "subcmd_catch" ELSE "done"
                  /\ outcome' = IF hasCatch THEN "running" ELSE "hung"
             ELSE IF Design = "design-a" /\ Mutant = "ignore_hup_eof"
                  THEN /\ errKind' = "none"
                       /\ phase' = "done"
                       /\ outcome' = "hung"
                  ELSE /\ errKind' = "eof_hup"
                       /\ phase' = IF hasCatch THEN "subcmd_catch" ELSE "done"
                       /\ outcome' = IF hasCatch THEN "running" ELSE "hung"
  /\ UNCHANGED <<termState, hasCatch, msgPrinted>>

ReadFileError ==
  /\ Running
  /\ phase = "write_io"
  /\ Class /= "ideal"
  /\ errKind = "none"
  /\ errOnOpenTerm' = (termState = "open")
  /\ errKind' = "eio_file"
  /\ phase' = "exit_handler"
  /\ UNCHANGED <<termState, hasCatch, outcome, msgPrinted>>

NormalComplete ==
  /\ Running
  /\ termState = "open"
  /\ errKind = "none"
  /\ phase \in {"write_io", "stdin_prompt"}
  /\ phase' = "done"
  /\ outcome' = "ok_0"
  /\ UNCHANGED <<termState, errKind, errOnOpenTerm, hasCatch, msgPrinted>>

SubcmdCatch ==
  /\ Running
  /\ phase = "subcmd_catch"
  /\ IF errKind = "TerminalHungUp" /\ Design = "design-a" /\ Mutant /= "swallow_catch"
     THEN /\ phase' = "exit_handler"
          /\ msgPrinted' = msgPrinted
          /\ outcome' = "running"
     ELSE /\ phase' = "done"
          /\ msgPrinted' = "swallowed"
          /\ outcome' = "error_1"
  /\ UNCHANGED <<termState, errKind, errOnOpenTerm, hasCatch>>

ExitHandler ==
  /\ Running
  /\ phase = "exit_handler"
  /\ phase' = "done"
  /\ IF errKind = "TerminalHungUp"
     THEN /\ outcome' = "quiet_129"
          /\ msgPrinted' = "none"
     ELSE IF Design = "design-b" /\ termState = "hung_up" /\ errKind \in {"OutputWriteFailed", "eio_tty", "eof_hup"}
          THEN /\ outcome' = "quiet_129"
               /\ msgPrinted' = "none"
          ELSE IF errKind = "eio_file"
               THEN /\ outcome' = "error_1"
                    /\ msgPrinted' = "file_err"
               ELSE IF errKind = "OutputWriteFailed"
                    THEN /\ outcome' = "error_1"
                         /\ msgPrinted' = "write_failed"
                    ELSE /\ outcome' = "error_1"
                         /\ msgPrinted' = "disk"
  /\ UNCHANGED <<termState, errKind, errOnOpenTerm, hasCatch>>

Finished == phase = "done" /\ outcome /= "running"

Next ==
  \/ TerminalClose
  \/ WriteTtyFail
  \/ ReadStdinHangup
  \/ ReadFileError
  \/ NormalComplete
  \/ SubcmdCatch
  \/ ExitHandler
  \/ (Finished /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

FairSpec ==
  Spec
  /\ WF_vars(WriteTtyFail)
  /\ WF_vars(ReadStdinHangup)
  /\ WF_vars(NormalComplete)
  /\ WF_vars(SubcmdCatch)
  /\ WF_vars(ExitHandler)

(* When the terminal is gone and no file error happened, CLI exits quietly with 129. *)
GoneIsQuiet ==
  (Finished /\ termState = "hung_up" /\ ~errOnOpenTerm /\ errKind /= "eio_file") =>
    /\ outcome = "quiet_129"
    /\ msgPrinted = "none"

(* A real I/O error on an open terminal or on a file is still reported with exit 1. *)
OpenErrorIsReported ==
  (Finished /\ (errOnOpenTerm \/ errKind = "eio_file")) =>
    /\ outcome = "error_1"
    /\ msgPrinted \in {"disk", "write_failed", "swallowed", "file_err"}

Termination == <>Finished
=============================================================================
