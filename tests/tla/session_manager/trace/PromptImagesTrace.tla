------------------------ MODULE PromptImagesTrace ------------------------
(***************************************************************************)
(* Checks a real fx run against PromptImages.tla (D89).                    *)
(*                                                                         *)
(* tests/tla/drivers/session_manager/prompt-images.test.ts runs the built  *)
(* binary and writes one line per thing it observed, each a step of the    *)
(* spec, with images named by labels for their digests:                    *)
(*                                                                         *)
(*   Request  s, asked, sent, noted: a turn's first request, from the     *)
(*            gateway. `noted` holds an image only when its note names     *)
(*            that image's blob in the request's own session; a note       *)
(*            naming anything else gets a label outside Digests.           *)
(*   Write    s, refs, inline, listed: a turn's user item, from the log,   *)
(*            including one a conversion imported.                         *)
(*   Blobs    s, blobs: the files in a session's blobs folder.             *)
(*                                                                         *)
(* What nothing observes (each turn's or import's start, each save or     *)
(* failed save, each process exit) is left to TLC between lines; the      *)
(* driver makes no fork, so none happens. The run is accepted when some   *)
(* behavior of the spec makes every observation in order: the invariant   *)
(* TraceIncomplete fails exactly then.                                     *)
(***************************************************************************)
EXTENDS PromptImages, TraceData, TLC

VARIABLE l

traceVars == <<vars, l>>

ASSUME TLCSet(1, 0)

Hidden ==
    \/ \E s \in Sessions, a \in SUBSET Digests : Begin(s, a)
    \/ \E a \in SUBSET Digests : Import(a)
    \/ \E d \in Digests : Save(d) \/ SaveFails(d)
    \/ Finish \/ Crash \/ Restart

Form(e, d) == IF d \in e.refs THEN "ref" ELSE IF d \in e.inline THEN "inline" ELSE "none"

Observed(e) ==
    \/ /\ e.event = "Request"
       /\ Request
       /\ requests'[Len(requests')] = [s |-> e.s, asked |-> e.asked, sent |-> e.sent, noted |-> e.noted]
    \/ /\ e.event = "Write"
       /\ Write
       /\ log'[e.s][Len(log'[e.s])] =
            [asked |-> e.refs \cup e.inline,
             images |-> [d \in Digests |-> Form(e, d)],
             listed |-> e.listed]
    \/ /\ e.event = "Blobs"
       /\ blobs[e.s] = e.blobs
       /\ UNCHANGED vars

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ \/ Hidden /\ UNCHANGED l
       \/ Observed(Trace[l]) /\ l' = l + 1

\* Prints the furthest line matched, which names the rejected one.
Progress ==
    IF l > TLCGet(1)
    THEN TLCSet(1, l) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

TraceIncomplete == l <= Len(Trace)
=============================================================================
