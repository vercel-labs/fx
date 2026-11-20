-------------------------- MODULE MCAcpTurnEvents --------------------------
(* Exhaustive model of AcpTurnEvents: two turns, two progress reports and   *)
(* one model call per turn, and two compactions, in every order of reports, *)
(* compaction stages and outcomes, and deliveries. The configs set the     *)
(* parts the client lists; AcpTurnEventsToday sets Rules to FALSE.         *)
EXTENDS AcpTurnEvents
=============================================================================
