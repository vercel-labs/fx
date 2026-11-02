-------------------------- MODULE PR1092Steering ---------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANT MaxMessages, MaxSteps
Kinds == {"steering", "restored", "feedback", "plain"}
Entry == [kind : Kinds, after : 0..MaxSteps, valid : BOOLEAN]
VARIABLES steps, messages, saved, cancelled
vars == <<steps, messages, saved, cancelled>>
TypeOK == /\ steps \in 0..MaxSteps /\ messages \in Seq(Entry) /\ Len(messages) <= MaxMessages
          /\ saved \in Seq(Entry) /\ cancelled \in BOOLEAN
Init == /\ steps = 0 /\ messages = <<>> /\ saved = <<>> /\ cancelled = FALSE
ToolResult == /\ ~cancelled /\ steps < MaxSteps /\ steps' = steps + 1
              /\ UNCHANGED <<messages, saved, cancelled>>
TypeMessage(k,v) == /\ ~cancelled /\ Len(messages) < MaxMessages
                    /\ messages' = Append(messages, [kind |-> k, after |-> steps, valid |-> v])
                    /\ UNCHANGED <<steps, saved, cancelled>>
Retain(e) == e.valid /\ e.kind # "plain"
Cancel == /\ ~cancelled /\ cancelled' = TRUE
          /\ saved' = SelectSeq(messages, LAMBDA e : Retain(e))
          /\ UNCHANGED <<steps, messages>>
Next == ToolResult \/ (\E k \in Kinds, v \in BOOLEAN : TypeMessage(k,v)) \/ Cancel \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
Expected == SelectSeq(messages, LAMBDA e : e.valid /\ e.kind \in {"steering", "restored", "feedback"})
SavedExactlyMarkedTail == cancelled => saved = Expected
PlainTailExcluded == \A i \in 1..Len(saved) : saved[i].kind # "plain"
AnchorsPreserved == cancelled => \A i \in 1..Len(saved) : saved[i].after = Expected[i].after
=============================================================================
