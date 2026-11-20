--------------------------- MODULE MCAcpConfigTurn ---------------------------
(* Exhaustive model of AcpConfigTurn: two providers, two turns of two      *)
(* model requests, and two changes, in every order.                        *)
EXTENDS AcpConfigTurn

MCProviders == {"gateway", "codex"}
=============================================================================
