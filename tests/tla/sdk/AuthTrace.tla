------------------------------ MODULE AuthTrace ------------------------------
(* Replays a run of the real authorizer through ProviderAuth's own Next. Each
   step must produce exactly the next observed event. TLC breaking
   NotAllMatched means every event matched; finishing the search without
   breaking it means the run diverged from the model. *)
EXTENDS ProviderAuth, AuthObserved, Sequences, TLC

VARIABLE i

TraceInit == Init /\ i = 0

TraceNext ==
  /\ i < Len(Observed)
  /\ Next
  /\ ev' = Observed[i + 1]
  /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, i>>

NotAllMatched == i < Len(Observed)

\* Prints how far the replay got, so a divergence names its event.
Matched == PrintT(<<"AUTH_MATCHED", i>>)
=============================================================================
