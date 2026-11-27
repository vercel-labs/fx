---------------------------- MODULE DurableHandOff ----------------------------
(***************************************************************************)
(* DurableSession.tla with a host that hands the session off: it asks one  *)
(* worker's process to stop, as SIGTERM or a deploy does                   *)
(* (`agent.handOff()` in sdk/durable.js).                                  *)
(*                                                                         *)
(* An asked worker takes no new work: its agent sends every delivery back  *)
(* to the queue. Its running turn stops at the next save before a model    *)
(* request after the turn's first one (src/core/quiesce/quiesce.zig): the  *)
(* step it finished is recorded, it writes turn_yield, it releases the     *)
(* session without naming a cut-off, and the same message comes back for   *)
(* another worker, which continues the turn from that record. In this      *)
(* turn the only such save is the one after the tool returns, before the   *)
(* model's second request; a resumed turn's first request is its own       *)
(* first, so it never yields there. A turn that reaches no such save in    *)
(* time is cut off at the hand-off's bound, as at its deadline (Deadline), *)
(* and the asked worker does not take the session again.                  *)
(*                                                                         *)
(* HandOffBug plants one defect; "none" is the design:                     *)
(*   "dies"          today: the process ends at once, holding its lease    *)
(*   "takes_work"    an asked worker still starts a claim                  *)
(*   "retakes"       an asked worker takes the session again at the bound  *)
(*   "yield_first"   a turn yields before its first model request          *)
(*   "counts_cutoff" the yield's release names the turn as cut off         *)
(***************************************************************************)
EXTENDS DurableSession

CONSTANT HandOffBug

ASSUME HandOffBug \in {"none", "dies", "takes_work", "retakes", "yield_first", "counts_cutoff"}

VARIABLE asked   \* whether the host asked each worker's process to stop

hvars == <<vars, asked>>

HTypeOK ==
    /\ pc \in [Workers -> {"none", "early", "announce", "model1", "ahead", "tool", "model2", "done", "stopped"}]
    /\ epoch \in [Workers -> 0..MaxEpoch]
    /\ frozen \in [Workers -> BOOLEAN]
    /\ lease \in [holder: Workers \cup {None}, epoch: 0..MaxEpoch, live: BOOLEAN]
    /\ progress \in Progress
    /\ runs \in 0..(MaxEpoch + 1)
    /\ ids \in 0..(MaxEpoch + 1)
    /\ ui \in Seq([e: 0..MaxEpoch, legit: BOOLEAN])
    /\ freezes \in 0..MaxFreezes
    /\ froze \in [Workers -> BOOLEAN]
    /\ chain \in Nat
    /\ cutoffs \in Nat
    /\ seen \in [Workers -> [chain: Nat, progress: Progress, epoch: 0..MaxEpoch, cutoffs: Nat]]
    /\ lapse \in Workers \cup {"none", "open"}
    /\ act \in [name: {"Init", "Start", "Claim", "Announce", "Model1", "Intent", "ToolEnd", "Model2",
                       "Freeze", "Wake", "Deadline", "Expire", "AskHandOff", "Yield", "Die"},
                w: Workers \cup {None}]
    /\ asked \in [Workers -> BOOLEAN]

HInit == Init /\ asked = [w \in Workers |-> FALSE]

\* The host asks w's process to stop. Once in the model, so the other
\* worker can still continue the turn.
AskHandOff(w) ==
    /\ \A v \in Workers : ~asked[v]
    /\ asked' = [asked EXCEPT ![w] = TRUE]
    /\ UNCHANGED <<pc, epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse>>
    /\ act' = [name |-> "AskHandOff", w |-> w]

\* An asked worker starts no claim; its agent sends the delivery back.
HStart(w) == (~asked[w] \/ HandOffBug = "takes_work") /\ Start(w) /\ UNCHANGED asked

\* Where an asked worker heads the chain, its tool's end is the turn's
\* yield (Yield) instead.
HToolEnd(w) == ~(asked[w] /\ Heads(w) /\ HandOffBug # "dies") /\ ToolEnd(w) /\ UNCHANGED asked

\* At the bound an asked worker cuts its turn off as at the deadline, and
\* does not take the session again.
HDeadline(w) ==
    /\ Deadline(w)
    /\ ((asked[w] /\ HandOffBug # "retakes") => pc'[w] # "announce")
    /\ UNCHANGED asked

\* The turn yields at the save after the tool returns, before the model's
\* second request: the result's record lands, then turn_yield, then the
\* release, which names no cut-off. The same message comes back at once.
Yield(w) ==
    /\ HandOffBug # "dies"
    /\ asked[w]
    /\ pc[w] = "tool"
    /\ ~frozen[w]
    /\ Heads(w)
    /\ progress' = "result"
    /\ pc' = [pc EXCEPT ![w] = "none"]
    /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
    \* tool_end, then turn_yield
    /\ ui' = ui \o <<Line(w), Line(w)>>
    \* the result's record, then the release
    /\ chain' = chain + 2
    /\ cutoffs' = IF HandOffBug = "counts_cutoff" THEN 1 ELSE 0
    /\ lapse' = "none"
    /\ UNCHANGED <<epoch, frozen, runs, ids, freezes, froze, seen, asked>>
    /\ act' = [name |-> "Yield", w |-> w]

\* Planted: the turn yields at its claim, before its first model request,
\* so it made no progress.
YieldFirst(w) ==
    /\ HandOffBug = "yield_first"
    /\ asked[w]
    /\ pc[w] = "announce"
    /\ ~frozen[w]
    /\ Heads(w)
    /\ pc' = [pc EXCEPT ![w] = "none"]
    /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
    \* turn_start or turn_resume, then turn_yield
    /\ ui' = ui \o <<Line(w), Line(w)>>
    /\ chain' = chain + 1
    /\ lapse' = "none"
    /\ UNCHANGED <<epoch, frozen, progress, runs, ids, freezes, froze, cutoffs, seen, asked>>
    /\ act' = [name |-> "Yield", w |-> w]

\* Today: SIGTERM ends the process at once, and its lease stays until the
\* World or the queue finds it dead.
Die(w) ==
    /\ HandOffBug = "dies"
    /\ asked[w]
    /\ pc[w] \notin {"none", "stopped", "done"}
    /\ pc' = [pc EXCEPT ![w] = "none"]
    /\ frozen' = [frozen EXCEPT ![w] = FALSE]
    /\ lease' = IF lease.holder = w THEN [lease EXCEPT !.live = FALSE] ELSE lease
    /\ lapse' = IF QueueHeld /\ lease.holder = w /\ lapse = "none" THEN "open" ELSE lapse
    /\ UNCHANGED <<epoch, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, asked>>
    /\ act' = [name |-> "Die", w |-> w]

HNext ==
    \E w \in Workers :
        \/ HStart(w)
        \/ Claim(w) /\ UNCHANGED asked
        \/ Announce(w) /\ UNCHANGED asked
        \/ Model1(w) /\ UNCHANGED asked
        \/ Intent(w) /\ UNCHANGED asked
        \/ HToolEnd(w)
        \/ Model2(w) /\ UNCHANGED asked
        \/ Freeze(w) /\ UNCHANGED asked
        \/ Wake(w) /\ UNCHANGED asked
        \/ HDeadline(w)
        \/ Expire(w) /\ UNCHANGED asked
        \/ AskHandOff(w)
        \/ Yield(w)
        \/ YieldFirst(w)
        \/ Die(w)

HSpec == HInit /\ [][HNext]_hvars

-----------------------------------------------------------------------------
(* Properties *)

\* A worker the host asked to stop lets the session go when it stops, so the
\* next delivery need not wait for its lease to lapse.
HandOffReleases == \A w \in Workers : asked[w] /\ pc[w] \in {"none", "done"} => lease.holder # w

\* An asked worker starts no claim and takes no session back: its process is
\* going away, so a turn it took would end as a crash.
AskedClaimsNothing ==
    act.name \in {"Start", "Deadline"} => ~(asked[act.w] /\ pc[act.w] \in {"early", "announce"})

\* A yield leaves the turn further than the claim found it: the first model
\* request always goes out.
YieldMakesProgress == act.name = "Yield" => progress # seen[act.w].progress

\* A yield is not a cut-off: its release names no turn, so it never counts
\* toward MaxCutoffs.
YieldIsNoCutoff == act.name = "Yield" => cutoffs = 0

\* Witness, expected to FAIL: another worker finishes the turn after a
\* hand-off.
NotContinued == ~(progress = "done" /\ \E w \in Workers : asked[w] /\ pc[w] # "done")
=============================================================================
