------------------------ MODULE AcpCommandOutputTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one shell call of the real `fx acp` binary   *)
(* against AcpCommandOutput. The generated AcpCommandOutputObs module      *)
(* gives two sequences:                                                    *)
(*   TraceLog: the chunks the driver's command makes the runner deliver,   *)
(*     [kind |-> "chunk", src, bytes] and finally [kind |-> "finish", src] *)
(*   Frames: the progress updates fx sent for the call, in order,          *)
(*     [text, valid], where valid says the frame was valid UTF-8 on the    *)
(*     wire.                                                               *)
(* Runs of ASCII are collapsed to one A on both sides, so a padded line    *)
(* stays short; that keeps every hold and escape decision, which looks     *)
(* only at non-ASCII bytes.                                                *)
(*                                                                         *)
(* A chunk whose text is empty sends no frame. NotDone is a sentinel: TLC *)
(* reporting it violated means every chunk and every frame matched.        *)
(***************************************************************************)
EXTENDS AcpCommandOutput, AcpCommandOutputObs

VARIABLES i, j

traceVars == <<vars, i, j>>

RECURSIVE Collapse(_)
Collapse(s) ==
    IF Len(s) <= 1 THEN s
    ELSE IF s[1] = "A" /\ s[2] = "A" THEN Collapse(Tail(s))
    ELSE <<s[1]>> \o Collapse(Tail(s))

TraceInit == /\ i = 0
             /\ j = 0
             /\ Init

TraceNext ==
    /\ i < Len(TraceLog)
    /\ \E o \in {TraceLog[i + 1]} :
           LET emitted == IF o.kind = "chunk" THEN Emitted(o.src, o.bytes) ELSE Flushed(o.src)
           IN /\ IF o.kind = "chunk" THEN Chunk(o.src, o.bytes) ELSE Finish(o.src)
              /\ IF emitted = <<>>
                 THEN j' = j
                 ELSE /\ j < Len(Frames)
                      /\ Frames[j + 1].valid
                      /\ Collapse(emitted) = Frames[j + 1].text
                      /\ j' = j + 1
    /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog) \/ j < Len(Frames)
=============================================================================
