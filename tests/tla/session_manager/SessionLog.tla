---------------------------- MODULE SessionLog ----------------------------
(***************************************************************************)
(* Step: L1 log. One append-only log file.                                *)
(*                                                                         *)
(* Models write() into the page cache, fsync at a durability point, an fx *)
(* crash (the kernel keeps every written byte), a machine crash (only the *)
(* fsynced prefix is guaranteed; the rest may be lost and the new last    *)
(* line may be torn) and the torn-tail cut plus fsync done by open().     *)
(*                                                                         *)
(* Design: system-design.md "Line format" and "Durable State And Schema". *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT MaxLines

VARIABLES
    log,      \* file contents: a sequence of lines [seq, done]
    durable,  \* length of the prefix that is on stable storage
    acked,    \* number of lines a caller was told are durable
    status    \* "open", "writing" or "down"

vars == <<log, durable, acked, status>>

Line(n, d) == [seq |-> n, done |-> d]

LastDone == Len(log) = 0 \/ log[Len(log)].done

TypeOK ==
    /\ log \in Seq([seq : 1..MaxLines, done : BOOLEAN])
    /\ Len(log) <= MaxLines
    /\ durable \in 0..MaxLines
    /\ acked \in 0..MaxLines
    /\ status \in {"open", "writing", "down"}

Init ==
    /\ log = <<>>
    /\ durable = 0
    /\ acked = 0
    /\ status = "open"

(* write() starts: bytes are in the page cache, the newline is not yet. *)
BeginWrite ==
    /\ status = "open"
    /\ Len(log) < MaxLines
    /\ log' = Append(log, Line(Len(log) + 1, FALSE))
    /\ status' = "writing"
    /\ UNCHANGED <<durable, acked>>

(* write() returns: the whole line, including its newline, is written. *)
FinishWrite ==
    /\ status = "writing"
    /\ log' = [log EXCEPT ![Len(log)].done = TRUE]
    /\ status' = "open"
    /\ UNCHANGED <<durable, acked>>

(* Durability point: fsync, then acknowledge to the caller. *)
Fsync ==
    /\ status = "open"
    /\ durable' = Len(log)
    /\ acked' = Len(log)
    /\ UNCHANGED <<log, status>>

(* fx dies. The kernel keeps every byte already written. *)
ProcessCrash ==
    /\ status \in {"open", "writing"}
    /\ status' = "down"
    /\ UNCHANGED <<log, durable, acked>>

(* Machine crash (OS crash, or a power cut on Linux; D3 leaves a macOS   *)
(* power cut outside the model): bytes after the durable prefix may be   *)
(* lost, and the new                                                      *)
(* last line may be torn.                                                *)
PowerLoss ==
    /\ \E k \in durable..Len(log), torn \in BOOLEAN :
          LET kept == SubSeq(log, 1, k) IN
          log' = IF torn /\ k > durable
                    THEN [kept EXCEPT ![k].done = FALSE]
                    ELSE kept
    /\ status' = "down"
    /\ UNCHANGED <<durable, acked>>

(* open(.resume): cut a torn last line, fsync, accept writes again. *)
Recover ==
    /\ status = "down"
    /\ LET repaired == IF LastDone THEN log ELSE SubSeq(log, 1, Len(log) - 1)
       IN /\ log' = repaired
          /\ durable' = Len(repaired)
    /\ status' = "open"
    /\ UNCHANGED acked

Next ==
    \/ BeginWrite
    \/ FinishWrite
    \/ Fsync
    \/ ProcessCrash
    \/ PowerLoss
    \/ Recover

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* seq equals the line's position: no gaps and no duplicates.
SeqContiguous == \A i \in 1..Len(log) : log[i].seq = i

\* Only the final line can be incomplete.
OnlyTailTorn == \A i \in 1..(Len(log) - 1) : log[i].done

\* A line the caller was told is durable is never lost or torn.
AckedSurvive ==
    /\ acked <= durable
    /\ durable <= Len(log)
    /\ \A i \in 1..acked : log[i].done

\* An open log never ends in a torn line.
OpenIsClean == status = "open" => LastDone

(* Note: after a machine crash, a line past `acked` can vanish and its seq *)
(* is handed out again. Hosts must treat only acknowledged seqs as       *)
(* stable (system-design.md "Acknowledged seq").                         *)
=============================================================================
