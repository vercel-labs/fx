------------------------- MODULE TurnLifecycleLog -------------------------
(***************************************************************************)
(* Checks a log fx saved against TurnLifecycle.tla, after the fact.        *)
(*                                                                         *)
(* Only the disk is known: the log's kinds, in order (`Target`, from       *)
(* SavedLog.tla). The process state (status, fresh), and with it every     *)
(* close, crash and reopen that wrote no line, is left to TLC. The log is  *)
(* accepted when some behavior of the spec writes exactly these lines:     *)
(* every step keeps the log a prefix of `Target`, and the invariant        *)
(* `NotWritten` fails once the whole log is written.                       *)
(*                                                                         *)
(* check_saved_logs.py writes SavedLog.tla and runs this.                  *)
(***************************************************************************)
EXTENDS TurnLifecycle, SavedLog, TLC

ASSUME TLCSet(1, 0)

LogNext == Next /\ Prefix(log', Target)

LogSpec == Init /\ [][LogNext]_vars

\* Prints the longest prefix written, which names the rejected line.
Progress ==
    IF Len(log) > TLCGet(1)
    THEN TLCSet(1, Len(log)) /\ PrintT(<<"matched_lines", Len(log)>>)
    ELSE TRUE

NotWritten == log # Target
=============================================================================
