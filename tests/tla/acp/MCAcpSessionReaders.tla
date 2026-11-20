------------------------- MODULE MCAcpSessionReaders -------------------------
(***************************************************************************)
(* Exhaustive model of AcpSessionReaders: an owner and a follower, each    *)
(* with two requests, two turns, and the owner's close. Every order of     *)
(* claims, reaps, joins, frees, and closes is reached.                     *)
(***************************************************************************)
EXTENDS AcpSessionReaders
=============================================================================
