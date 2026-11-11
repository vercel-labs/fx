--------------------------- MODULE AcpCommandOutput ---------------------------
(***************************************************************************)
(* How fx acp turns a running command's output chunks into tool_call      *)
(* progress text (CommandOutputText and AcpContext.sendCommandOutput in    *)
(* src/acp/prompt.zig).                                                    *)
(*                                                                         *)
(* The command runner cuts output at line ends and byte counts, so a      *)
(* chunk can end partway through a UTF-8 character. Each source, one      *)
(* call's stdout or stderr, holds the unfinished end of its last chunk,    *)
(* at most three bytes, and puts it before its next chunk. Bytes that are *)
(* not valid UTF-8 go out as a \xNN escape. When the source ends, the held *)
(* bytes go out escaped before the call's final update. Empty text sends   *)
(* no update.                                                              *)
(*                                                                         *)
(* Bytes are modeled by class: A is ASCII, C a continuation byte, L2, L3   *)
(* and L4 lead bytes of 2-, 3- and 4-byte sequences, and X a byte that     *)
(* never starts one, such as FF. In sent text, E is one escape. The        *)
(* classes leave out overlong forms and surrogates, which                  *)
(* text_utils.dupeValidUtf8 also escapes.                                  *)
(*                                                                         *)
(* Carry = FALSE is fx before the fix, which sent each raw chunk.          *)
(* SharedTail = TRUE is a planted bug: one held tail for every source.     *)
(* Flush = FALSE is a planted bug: held bytes are dropped at the end.      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Sources, Classes, MaxLen, MaxChunk, Carry, SharedTail, Flush

ASSUME Classes \subseteq {"A", "C", "L2", "L3", "L4", "X"}

Leads == {"L2", "L3", "L4"}

LeadLen(c) == CASE c = "L2" -> 2 [] c = "L3" -> 3 [] c = "L4" -> 4

Max(S) == CHOOSE x \in S : \A y \in S : x >= y

(* text_utils.dupeValidUtf8: keep each whole sequence, escape every other  *)
(* byte, left to right.                                                    *)
RECURSIVE Esc(_)
Esc(s) ==
    IF s = <<>> THEN <<>>
    ELSE IF Head(s) = "A" THEN <<"A">> \o Esc(Tail(s))
    ELSE IF Head(s) \in Leads
            /\ Len(s) >= LeadLen(Head(s))
            /\ \A k \in 2..LeadLen(Head(s)) : s[k] = "C"
         THEN SubSeq(s, 1, LeadLen(Head(s))) \o Esc(SubSeq(s, LeadLen(Head(s)) + 1, Len(s)))
    ELSE <<"E">> \o Esc(Tail(s))

(* Valid UTF-8 text; an escape is ASCII. *)
Valid(s) == Esc(s) = s

(* text_utils.incompleteUtf8Tail: where the trailing sequence a later chunk *)
(* may still complete starts, or Len(s) + 1 when there is none. Only the   *)
(* last three bytes can start one.                                         *)
HoldFrom(s) ==
    LET n == Len(s)
        starts == {k \in (IF n > 3 THEN n - 2 ELSE 1)..n : s[k] # "C"}
        k == IF starts = {} THEN 0 ELSE Max(starts)
    IN IF k > 0 /\ s[k] \in Leads /\ n - k + 1 < LeadLen(s[k]) THEN k ELSE n + 1

Key(s) == IF SharedTail THEN "shared" ELSE s

Keys == IF SharedTail THEN {"shared"} ELSE Sources

Chunks == UNION {[1..n -> Classes] : n \in 1..MaxChunk}

VARIABLES sent, pending, text, valid, done

vars == <<sent, pending, text, valid, done>>

(* The bytes source s works on when chunk c arrives, where it cuts them,   *)
(* and the text fx sends for c.                                            *)
Raw(s, c) == IF Carry THEN pending[Key(s)] \o c ELSE c
Cut(s, c) == IF Carry THEN HoldFrom(Raw(s, c)) ELSE Len(c) + 1
Emitted(s, c) == IF Carry THEN Esc(SubSeq(Raw(s, c), 1, Cut(s, c) - 1)) ELSE c

(* The text fx sends when source s ends. *)
Flushed(s) == IF Flush THEN Esc(pending[Key(s)]) ELSE <<>>

Init == /\ sent = [s \in Sources |-> <<>>]
        /\ pending = [k \in Keys |-> <<>>]
        /\ text = [s \in Sources |-> <<>>]
        /\ valid = TRUE
        /\ done = [s \in Sources |-> FALSE]

(* Source s delivers chunk c. *)
Chunk(s, c) ==
    /\ ~done[s]
    /\ Len(sent[s]) + Len(c) <= MaxLen
    /\ pending' = [pending EXCEPT ![Key(s)] = SubSeq(Raw(s, c), Cut(s, c), Len(Raw(s, c)))]
    /\ text' = [text EXCEPT ![s] = @ \o Emitted(s, c)]
    /\ valid' = Valid(Emitted(s, c))
    /\ sent' = [sent EXCEPT ![s] = @ \o c]
    /\ UNCHANGED done

(* Source s ends: the command's output completes or its card gets its     *)
(* final update.                                                           *)
Finish(s) ==
    /\ ~done[s]
    /\ text' = [text EXCEPT ![s] = @ \o Flushed(s)]
    /\ valid' = Valid(Flushed(s))
    /\ pending' = [pending EXCEPT ![Key(s)] = <<>>]
    /\ done' = [done EXCEPT ![s] = TRUE]
    /\ UNCHANGED sent

Next == \E s \in Sources : \/ \E c \in Chunks : Chunk(s, c)
                           \/ Finish(s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK == /\ \A s \in Sources : Len(sent[s]) <= MaxLen
          /\ valid \in BOOLEAN
          /\ done \in [Sources -> BOOLEAN]

(* Every progress update fx sends is valid UTF-8. *)
ProgressValidUtf8 == valid

(* A source never holds more than three bytes. *)
TailBounded == \A k \in Keys : Len(pending[k]) <= 3

(* What a source sent plus what it holds is its output, escaped, with     *)
(* nothing lost, repeated, or taken from another source.                   *)
NothingLost == \A s \in Sources : text[s] \o Esc(pending[Key(s)]) = Esc(sent[s])
=============================================================================
