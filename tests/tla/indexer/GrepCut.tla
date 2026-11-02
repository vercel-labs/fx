---- MODULE GrepCut ----
\* Parallel grep in grep_search.zig: workers claim candidate batches through
\* one counter, finish in any order, stop once finished batches hold the
\* collection cap, and one batch may run out of memory. The merge walks
\* outcomes in candidate order up to the cap and fails for running out of
\* memory only when it reaches the failed batch before the cut.
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS B, W, Cap, MaxM, ClaimInOrder, MergeHonorsOom

Batches == 1..B
Workers == 1..W
NoOom == B + 1

VARIABLES m, oom, inflight, claimed, done, nextb, stop, doneTotal, oomFrom, pc, merged, history
vars == <<m, oom, inflight, claimed, done, nextb, stop, doneTotal, oomFrom, pc, merged, history>>

Init ==
    /\ m \in [Batches -> 0..MaxM]
    /\ oom \in Batches \cup {NoOom}
    /\ inflight = [w \in Workers |-> 0]
    /\ claimed = {} /\ done = {} /\ nextb = 1 /\ stop = FALSE /\ doneTotal = 0
    /\ oomFrom = NoOom /\ pc = "run"
    /\ merged = [count |-> 0, parts |-> <<>>, error |-> FALSE]
    /\ history = <<>>

Claim(w, b) ==
    /\ pc = "run" /\ inflight[w] = 0 /\ ~stop /\ b \in Batches \ claimed
    /\ (ClaimInOrder => b = nextb)
    /\ inflight' = [inflight EXCEPT ![w] = b]
    /\ claimed' = claimed \cup {b}
    /\ nextb' = nextb + 1
    /\ history' = Append(history, <<"Claim", w, b>>)
    /\ UNCHANGED <<m, oom, done, stop, doneTotal, oomFrom, pc, merged>>

Finish(w) ==
    LET b == inflight[w] IN
    /\ pc = "run" /\ b # 0 /\ b # oom
    /\ done' = done \cup {b}
    /\ doneTotal' = doneTotal + m[b]
    /\ stop' = (stop \/ doneTotal + m[b] >= Cap)
    /\ inflight' = [inflight EXCEPT ![w] = 0]
    /\ history' = Append(history, <<"Finish", w, b>>)
    /\ UNCHANGED <<m, oom, claimed, nextb, oomFrom, pc, merged>>

Fail(w) ==
    LET b == inflight[w] IN
    /\ pc = "run" /\ b # 0 /\ b = oom
    /\ oomFrom' = IF b < oomFrom THEN b ELSE oomFrom
    /\ stop' = TRUE
    /\ inflight' = [inflight EXCEPT ![w] = 0]
    /\ history' = Append(history, <<"Fail", w, b>>)
    /\ UNCHANGED <<m, oom, claimed, done, nextb, doneTotal, pc, merged>>

Idle == \A w \in Workers : inflight[w] = 0
Finished == Idle /\ (stop \/ claimed = Batches)

RECURSIVE MergeFrom(_, _, _)
MergeFrom(b, acc, honors) ==
    IF b > B \/ acc.count >= Cap THEN acc
    ELSE IF honors /\ b >= oomFrom THEN [acc EXCEPT !.error = TRUE]
    ELSE LET got == IF b \in done THEN m[b] ELSE 0
             take == IF acc.count + got > Cap THEN Cap - acc.count ELSE got
         IN MergeFrom(b + 1, [acc EXCEPT !.count = acc.count + take, !.parts = Append(acc.parts, <<b, take>>)], honors)

RECURSIVE TruthFrom(_, _)
TruthFrom(b, acc) ==
    IF b > B \/ acc.count >= Cap THEN acc
    ELSE LET take == IF acc.count + m[b] > Cap THEN Cap - acc.count ELSE m[b]
         IN TruthFrom(b + 1, [acc EXCEPT !.count = acc.count + take, !.parts = Append(acc.parts, <<b, take>>)])

Truth == TruthFrom(1, [count |-> 0, parts |-> <<>>, error |-> FALSE])

RECURSIVE CumBefore(_)
CumBefore(b) == IF b <= 1 THEN 0 ELSE CumBefore(b - 1) + m[b - 1]

Merge ==
    /\ pc = "run" /\ Finished
    /\ merged' = MergeFrom(1, [count |-> 0, parts |-> <<>>, error |-> FALSE], MergeHonorsOom)
    /\ pc' = "merged"
    /\ history' = Append(history, <<"Merge", 0, 0>>)
    /\ UNCHANGED <<m, oom, inflight, claimed, done, nextb, stop, doneTotal, oomFrom>>

Next ==
    \/ \E w \in Workers, b \in Batches : Claim(w, b)
    \/ \E w \in Workers : Finish(w) \/ Fail(w)
    \/ Merge

Spec == Init /\ [][Next]_vars

\* Every success equals the sequential result, including where the cap cuts.
MergeCorrect == pc = "merged" => (merged.error \/ merged.parts = Truth.parts)
\* Running out of memory fails the search only when the failed batch was needed.
ErrorOnlyIfNeeded == (pc = "merged" /\ merged.error) => CumBefore(oomFrom) < Cap
\* A failure past the cut never fails the search.
NoErrorPastCut == (pc = "merged" /\ oom \in Batches /\ CumBefore(oom) >= Cap) => ~merged.error
\* Matches past the cut are buffered only by batches already running.
BufferBound == doneTotal <= Cap - 1 + W * MaxM
====
