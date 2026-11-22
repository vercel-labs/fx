------------------------- MODULE MCAcpSharedInput -------------------------
(***************************************************************************)
(* Exhaustive model of AcpSharedInput: the owner sends up to two requests   *)
(* and the follower one, in every order of sends, steers, queued prompts,  *)
(* cancels, loads, closes, and disconnects.                                 *)
(***************************************************************************)
EXTENDS AcpSharedInput
=============================================================================
