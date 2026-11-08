------------------------- MODULE MCAcpSessionTarget -------------------------
(* Exhaustive model of AcpSessionTarget: every order of up to two new      *)
(* sessions, restarts, oversized frames, and requests that name each       *)
(* target. MCFixed is TRUE for ACP v1's rules; the AcpSessionTargetBefore  *)
(* configs set it to FALSE to show fx before them.                         *)
EXTENDS AcpSessionTarget
=============================================================================
