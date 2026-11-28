--------------------------- MODULE HistoryLoadTrace ---------------------------
(***************************************************************************)
(* Trace validation: replays one run of the real fx through HistoryLoad's  *)
(* design "b". `tests/tla/drivers/session/history.test.ts` drives fx acp:  *)
(* a load that asks for pages, a prompt while older pages load, and pages  *)
(* to the log's start. It writes HistoryLoadObserved, which defines TCut   *)
(* (where fx started each page, by page end) and Observed: what the client *)
(* shows after each message the model sends, a turn of the newest page,   *)
(* the bottom marker, the reply, a page or a live turn, as                 *)
(*   [view, live, bottom, replied, more]                                   *)
(* with view and live the turns shown, by number, and more whether a       *)
(* cursor to an older page is left. The requirements the trace config      *)
(* names (BottomBounded, LoadBounded, TranscriptExact, BottomIsNewest,     *)
(* LiveBelowHistory, NoSilentGap) are checked on every state on the way.   *)
(*                                                                         *)
(* NotAllMatched is a sentinel: TLC reports it violated (exit 12) only     *)
(* after every observation matched a step of the model. A search that ends *)
(* without that violation means the run is not a behavior of the model.    *)
(***************************************************************************)
EXTENDS HistoryLoad, HistoryLoadObserved, Sequences

VARIABLE k

traceVars == <<vars, k>>

Shows(o) == view = o.view /\ live = o.live /\ bottom = o.bottom /\ replied = o.replied /\ (cursor > 0) = o.more

TraceInit == Init /\ k = 0

TraceNext ==
    \/ /\ k < Len(Observed)
       /\ Receive
       \* The observation is bound first, so priming Shows primes only the
       \* model's variables, not k.
       /\ \E o \in {Observed[k + 1]} : Shows(o)'
       /\ k' = k + 1
    \/ /\ \/ Load \/ Send \/ Prompt \/ LiveSend \/ ScrollTop \/ Page
       /\ UNCHANGED k

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotAllMatched == k < Len(Observed)
=============================================================================
