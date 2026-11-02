-------------------------- MODULE LeanUsageDrive --------------------------
(***************************************************************************)
(* The behaviors of LeanUsage that the Bun driver replays against the real *)
(* fx binary (driver/drive.ts). Two restrictions make a trace drivable:     *)
(*                                                                         *)
(* - fx fires a due 15-minute refresh on its next event-loop pass, so a    *)
(*   due Timer is taken before anything else happens;                      *)
(* - a running TUI's sign-in cannot be switched from the driver, so each   *)
(*   process keeps the identity it starts with (no Switch).                *)
(*                                                                         *)
(* Every behavior here is a behavior of LeanUsage, so its invariants hold. *)
(***************************************************************************)
EXTENDS LeanUsage

TimerDue(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ lastStart[p] # None
    /\ Since(lastStart[p], TIMER)

DriveNext ==
    IF \E p \in Procs : TimerDue(p)
    THEN \E p \in Procs : Timer(p)
    ELSE \/ Tick
         \/ \E p \in Procs :
               Open(p) \/ Close(p) \/ Manual(p) \/ Complete(p) \/ Fail(p)

DriveSpec == Init /\ [][DriveNext]_vars
=============================================================================
