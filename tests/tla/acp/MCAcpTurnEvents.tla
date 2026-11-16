-------------------------- MODULE MCAcpTurnEvents --------------------------
(* Exhaustive model of AcpTurnEvents: two turns, two progress reports, one *)
(* model call and one shell call per turn, and two compactions, in every   *)
(* order of reports, compaction stages and outcomes, and deliveries. The   *)
(* configs set the parts the client lists; AcpTurnEventsToday sets Rules   *)
(* to FALSE, and AcpTurnEventsRootField sets CommandMeta to FALSE.         *)
EXTENDS AcpTurnEvents
=============================================================================
