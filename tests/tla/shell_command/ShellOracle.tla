---------------------------- MODULE ShellOracle ----------------------------
(***************************************************************************)
(* Prints the model's emission set and Record(e) for every emission.       *)
(* bun/bridge.ts uses it to require that the runtime observed every        *)
(* modeled call, and to explain a mismatch. It never decides acceptance;   *)
(* ShellTrace does.                                                        *)
(***************************************************************************)
EXTENDS ShellContract, FiniteSets

Line(e) ==
  LET r == Record(e) IN
  <<"FXT_PREDICT", e.intent, e.shape, r.accepted, r.decoded, r.history, r.outcome>>

(* The count lets the bridge refuse a partial parse of the lines below.     *)
ASSUME PrintT(<<"FXT_EMITS", Cardinality(Emits)>>)
ASSUME \A e \in Emits : PrintT(Line(e))

OracleNext == UNCHANGED vars
=============================================================================
