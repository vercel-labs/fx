----------------------------- MODULE MCAcpJoin ------------------------------
(***************************************************************************)
(* Exhaustive model of AcpJoin: two joining connections, two turns of      *)
(* two updates each, and a running copy of one update. The copy drops an   *)
(* update, so the notice is sent. Every order of joins, saves, and ends    *)
(* is reached.                                                             *)
(***************************************************************************)
EXTENDS AcpJoin
=============================================================================
