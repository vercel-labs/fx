---- MODULE TraceFullDetailOrder ----
\* Checks one run of the real fx against FullDetailOrder: what Ctrl+O showed
\* live (ObservedLive) and after a resume (ObservedReplay), from
\* TraceData.tla, which drivers/full_detail/binary-to-spec.ts writes.
\*
\* TLC follows only behaviors whose events stay a prefix of the live view
\* (OnObservedRun). NotTheRun is violated exactly when the model reaches the
\* run: the turn ended or fx stopped, every event the live view showed
\* happened, and the resume shows what the binary showed. So a violation of
\* NotTheRun is the pass, and no violation means the model has no behavior
\* that shows what fx showed.
EXTENDS FullDetailOrder, TraceData

OnObservedRun ==
    /\ Len(events) <= Len(ObservedLive)
    /\ events = SubSeq(ObservedLive, 1, Len(events))

NotTheRun ==
    ~((committed \/ crashed) /\ events = ObservedLive /\ replay = ObservedReplay)
====
