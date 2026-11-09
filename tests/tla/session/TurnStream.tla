------------------------------ MODULE TurnStream ------------------------------
(***************************************************************************)
(* How an agent turn streams into the session log and commits, and how a   *)
(* tool result keeps the time it was made (`src/core/session/`             *)
(* `session_adapter.zig`: `appendProgress`, `commitTurn`, `streamedPrefix`,*)
(* `samePiece`; `src/core/agent/runtime/tool_batch.zig`,                   *)
(* `src/core/agent/execution_memory.zig`, `src/core/session/session.zig`). *)
(*                                                                         *)
(* After every model step the agent rebuilds the whole turn from its       *)
(* messages, and the adapter encodes it again. The pieces the open turn    *)
(* already holds must still match the rebuild: a match writes only the new *)
(* pieces, and a mismatch closes the turn as superseded and writes the     *)
(* rebuild afresh, never a mix of the two. A tool result's message carries *)
(* the time the turn took it, its birth, and each rebuild gives the result *)
(* that stamp, so an unchanged rebuild encodes the same bytes. A result    *)
(* whose message lost its stamp is stamped by each rebuild, as before, and *)
(* `samePiece` still lets it stand by parsing it.                          *)
(*                                                                         *)
(* A piece is abstract: the call it answers, a body that stands for every  *)
(* other byte of it, and its stamp. A stamp names the moment that made it  *)
(* and the call it was made for, so a stamp given to another call shows.   *)
(* Every rebuild runs in a new millisecond, the costly case.               *)
(*                                                                         *)
(* The edge cases each config may turn on:                                 *)
(*   MissedPaths  a result enters the turn without a stamp                 *)
(*   Compactions  compaction takes the turn's first results out of the     *)
(*                agent's view, so the rebuild no longer lines up          *)
(*   Recovery     fx stops mid-turn; resuming rebuilds the turn's messages *)
(*                from its recovery checkpoint and streams a new turn      *)
(*   Faults       a later rebuild gives a streamed result other content,   *)
(*                or loses one                                             *)
(*                                                                         *)
(* Mutant selects the design. "none" is fx as it is; "restamp" is fx       *)
(* before results kept their stamps; the rest are planted bugs.            *)
(* TurnStreamTrace.tla replays runs of the real binary through this model. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Calls, MaxBuilds, MissedPaths, Compactions, Recovery, Faults, Mutant

Mutants == {"none", "restamp", "lose_on_recover", "share_stamp", "bytes_only",
            "loose_compare", "mix_on_mismatch", "prefix_only"}

ASSUME Mutant \in Mutants
ASSUME MaxBuilds \in Nat
ASSUME {MissedPaths, Compactions, Recovery, Faults} \subseteq BOOLEAN

None == "none"

VARIABLES
  done,       \* the agent's tool results, as messages: call, birth, stamped
  cut,        \* leading results compaction took out of the agent's view
  changed,    \* calls whose rebuilt content no longer matches their stream
  dropped,    \* calls the rebuild no longer includes
  builds,     \* rebuilds so far; a rebuild that stamps uses builds + 1
  streamed,   \* the pieces the open turn holds, as they were written
  open,       \* whether the log has an open turn
  log,        \* the turn's lines in the session log
  committed,  \* whether the turn has ended
  final,      \* the commit's rebuild
  birthOf,    \* each call's stamp from when the turn took it (history)
  stampedAt,  \* calls whose result had a stamp when the turn took it
  recovered,  \* whether fx resumed the turn from its checkpoint
  shifted,    \* whether a compaction cut the view since the last write
  supersedes, \* turns closed because their stream differed
  unexplained,\* of those, closed with no fault and no compaction behind it
  reparsed,   \* streamed pieces of stamped results samePiece had to parse
  anyParsed,  \* streamed pieces of any result samePiece had to parse
  last        \* what the last stream or commit decided

vars == <<done, cut, changed, dropped, builds, streamed, open, log, committed,
          final, birthOf, stampedAt, recovered, shifted, supersedes,
          unexplained, reparsed, anyParsed, last>>

Range(s) == {s[i] : i \in DOMAIN s}

Stamp(n, c) == [at |-> n, of |-> c]
NoStamp == Stamp(0, None)
Piece(c, body, stamp) == [call |-> c, body |-> body, stamp |-> stamp]
NoPiece == Piece(None, 0, NoStamp)
Stamps == [at : 0..MaxBuilds, of : Calls]
Pieces == [call : Calls, body : {0, 1}, stamp : Stamps]
Results == [call : Calls, birth : Stamps, stamped : BOOLEAN]

Line(kind, p) == [kind |-> kind, piece |-> p]
Superseded == Line("superseded", NoPiece)
Interrupted == Line("interrupted", NoPiece)
End == Line("end", NoPiece)
AsLines(s) == [i \in 1..Len(s) |-> Line("piece", s[i])]

Decision(phase, stood, results, count) ==
  [phase |-> phase, stood |-> stood, results |-> results, reparsed |-> count]

(* The results the agent still sees, in order. *)
View ==
  SelectSeq(SubSeq(done, cut + 1, Len(done)), LAMBDA r : r.call \notin dropped)

(* `buildNormalExecutionMemory`: a result keeps its message's stamp. *)
StampFor(r, n) ==
  IF r.stamped /\ Mutant # "restamp" THEN r.birth ELSE Stamp(n, r.call)

(* The rebuild numbered n. *)
Fresh(n) ==
  LET v == View
  IN [i \in 1..Len(v) |->
        Piece(v[i].call, IF v[i].call \in changed THEN 1 ELSE 0, StampFor(v[i], n))]

SameBytes(x, y) == x = y

(* What samePiece's parser sees: every byte but the top-level stamp. *)
SameButStamp(x, y) == x.call = y.call /\ x.body = y.body

SamePiece(x, y) ==
  CASE Mutant = "bytes_only"    -> SameBytes(x, y)
    [] Mutant = "loose_compare" -> x.call = y.call
    [] OTHER                    -> SameBytes(x, y) \/ SameButStamp(x, y)

(* `streamedPrefix`: whether the open turn's pieces still stand. *)
Stands(b) ==
  /\ Mutant = "prefix_only" \/ Len(streamed) <= Len(b)
  /\ \A i \in 1..Len(streamed) : i <= Len(b) => SamePiece(streamed[i], b[i])

Mixes == Mutant = "mix_on_mismatch"

After(b) == SubSeq(b, Len(streamed) + 1, Len(b))
NewPieces(b) == IF Len(streamed) <= Len(b) THEN After(b) ELSE <<>>

Held(b) ==
  IF ~open THEN b
  ELSE IF Stands(b) \/ Mixes THEN streamed \o NewPieces(b)
  ELSE b

Lines(b) ==
  IF ~open THEN AsLines(b)
  ELSE IF Stands(b) \/ Mixes THEN AsLines(NewPieces(b))
  ELSE <<Superseded>> \o AsLines(b)

Faultless == changed \cup dropped = {}

(* The streamed pieces whose bytes the rebuild changed but samePiece let   *)
(* stand, and those of them that answer a result with a stamp.             *)
Parsed(b) ==
  {i \in 1..Len(streamed) : i <= Len(b) /\ ~SameBytes(streamed[i], b[i])}
StampedParsed(b) ==
  {i \in Parsed(b) : \E r \in Range(done) : r.call = b[i].call /\ r.stamped}

Decide(b, phase) ==
  LET stands     == ~open \/ Stands(b)
      supersede  == ~stands /\ ~Mixes
      count      == IF open /\ Stands(b) THEN Cardinality(Parsed(b)) ELSE 0
      stampedOne == IF open /\ Stands(b) THEN Cardinality(StampedParsed(b)) ELSE 0
  IN /\ supersedes' = supersedes + (IF supersede THEN 1 ELSE 0)
     /\ unexplained' = unexplained + (IF supersede /\ Faultless /\ ~shifted THEN 1 ELSE 0)
     /\ reparsed' = reparsed + stampedOne
     /\ anyParsed' = anyParsed + count
     /\ last' = Decision(phase, stands, Len(b), count)
     /\ shifted' = FALSE

Init ==
  /\ done = <<>>
  /\ cut = 0
  /\ changed = {}
  /\ dropped = {}
  /\ builds = 0
  /\ streamed = <<>>
  /\ open = FALSE
  /\ log = <<>>
  /\ committed = FALSE
  /\ final = <<>>
  /\ birthOf = [c \in Calls |-> NoStamp]
  /\ stampedAt = {}
  /\ recovered = FALSE
  /\ shifted = FALSE
  /\ supersedes = 0
  /\ unexplained = 0
  /\ reparsed = 0
  /\ anyParsed = 0
  /\ last = Decision(None, TRUE, 0, 0)

(* `tool_batch.zig`: a call finishes and its result enters the turn, with  *)
(* the time it was made, or, on a missed path, without one.                *)
RunTool(c, stamped) ==
  /\ ~committed
  \* A call id runs once, even after recovery or a fault took it out of view.
  /\ birthOf[c] = NoStamp
  /\ stamped \/ MissedPaths
  /\ LET own   == Stamp(builds, c)
         prior == done[Len(done)].birth
         birth == IF Mutant = "share_stamp" /\ Len(done) > 0 /\ prior.at = builds
                  THEN prior ELSE own
     IN /\ done' = Append(done, [call |-> c, birth |-> birth, stamped |-> stamped])
        /\ birthOf' = [birthOf EXCEPT ![c] = birth]
  /\ stampedAt' = IF stamped THEN stampedAt \cup {c} ELSE stampedAt
  /\ UNCHANGED <<cut, changed, dropped, builds, streamed, open, log, committed,
                 final, recovered, shifted, supersedes, unexplained, reparsed,
                 anyParsed, last>>

(* Compaction takes the first k results of the view out of it. *)
Compact(k) ==
  /\ Compactions
  /\ ~committed
  /\ k \in 1..(Len(done) - cut)
  /\ cut' = cut + k
  /\ shifted' = TRUE
  /\ UNCHANGED <<done, changed, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, supersedes, unexplained,
                 reparsed, anyParsed, last>>

(* fx stops mid-turn and resumes from the recovery checkpoint, which holds *)
(* the last rebuild; `appendExecutionMemoryChatMessages` gives each result *)
(* the stamp the checkpoint saved. Reopening the session ends the stale    *)
(* turn, and the resumed turn streams afresh.                              *)
Recover ==
  /\ Recovery
  /\ ~recovered
  /\ ~committed
  /\ open
  /\ LET v == View
     IN done' = [i \in 1..Len(v) |->
                   [call    |-> v[i].call,
                    birth   |-> StampFor(v[i], builds),
                    stamped |-> Mutant # "lose_on_recover"]]
  /\ cut' = 0
  /\ dropped' = {}
  /\ recovered' = TRUE
  /\ open' = FALSE
  /\ streamed' = <<>>
  /\ log' = log \o <<Interrupted>>
  /\ UNCHANGED <<changed, builds, committed, final, birthOf, stampedAt, shifted,
                 supersedes, unexplained, reparsed, anyParsed, last>>

(* A later rebuild gives a streamed result other content. *)
Change(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed)}
  /\ changed' = {c}
  /\ UNCHANGED <<done, cut, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, shifted, supersedes,
                 unexplained, reparsed, anyParsed, last>>

(* A later rebuild no longer has a streamed result, so the rest shift. *)
Drop(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed)}
  /\ dropped' = {c}
  /\ UNCHANGED <<done, cut, changed, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, shifted, supersedes,
                 unexplained, reparsed, anyParsed, last>>

(* `appendProgress`: the turn so far, before the next model request. *)
Stream ==
  /\ ~committed
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == Fresh(builds + 1)
     IN /\ log' = log \o Lines(b)
        /\ streamed' = Held(b)
        /\ Decide(b, "stream")
  /\ open' = TRUE
  /\ UNCHANGED <<done, cut, changed, dropped, committed, final, birthOf,
                 stampedAt, recovered>>

(* `commitTurn`: the finished turn, its end in the same batch. *)
Commit ==
  /\ ~committed
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == Fresh(builds + 1)
     IN /\ log' = log \o Lines(b) \o <<End>>
        /\ Decide(b, "commit")
        /\ final' = b
  /\ streamed' = <<>>
  /\ committed' = TRUE
  /\ open' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, birthOf, stampedAt, recovered>>

Next ==
  \/ \E c \in Calls, stamped \in BOOLEAN : RunTool(c, stamped)
  \/ \E c \in Calls : Change(c) \/ Drop(c)
  \/ \E k \in 1..Cardinality(Calls) : Compact(k)
  \/ Recover
  \/ Stream
  \/ Commit

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The lines after the last superseded or interrupted marker hold the live *)
(* turn.                                                                   *)
LastMark ==
  LET marks == {i \in 1..Len(log) : log[i].kind \in {"superseded", "interrupted"}}
  IN IF marks = {} THEN 0 ELSE CHOOSE i \in marks : \A j \in marks : j <= i

LiveTurn ==
  LET lines == SelectSeq(SubSeq(log, LastMark + 1, Len(log)), LAMBDA l : l.kind = "piece")
  IN [i \in 1..Len(lines) |-> lines[i].piece]

LiveCalls == [i \in 1..Len(LiveTurn) |-> LiveTurn[i].call]

Content(s) == [i \in 1..Len(s) |-> <<s[i].call, s[i].body>>]

AllStamped == \A r \in Range(done) : r.stamped

TypeOK ==
  /\ done \in Seq(Results)
  /\ cut \in 0..Cardinality(Calls)
  /\ changed \subseteq Calls
  /\ dropped \subseteq Calls
  /\ builds \in 0..MaxBuilds
  /\ streamed \in Seq(Pieces)
  /\ open \in BOOLEAN
  /\ committed \in BOOLEAN
  /\ \A i \in 1..Len(log) :
       \/ log[i].kind = "piece" /\ log[i].piece \in Pieces
       \/ log[i].kind \in {"superseded", "interrupted", "end"} /\ log[i].piece = NoPiece
  /\ stampedAt \subseteq Calls
  /\ {supersedes, unexplained, reparsed, anyParsed} \subseteq Nat

(* The committed turn holds the final rebuild's calls and content, and     *)
(* nothing a stale stream left.                                            *)
CommitIsFinal == committed => Content(LiveTurn) = Content(final)

(* When every result kept its stamp, the commit encodes exactly the bytes  *)
(* the log holds.                                                          *)
CommitIsWritten == committed /\ AllStamped => LiveTurn = final

(* A stream is superseded only when a rebuild really differs from it, or a *)
(* compaction moved the turn's first results out of the view.              *)
SupersedeExplained == unexplained = 0

(* No rebuild needs samePiece's parser for a result that kept its stamp. *)
NoReparseOfStamped == reparsed = 0

(* Every piece in the log carries a stamp made for its own call. *)
StampIsOwn ==
  \A i \in 1..Len(log) :
    log[i].kind = "piece" => log[i].piece.stamp.of = log[i].piece.call

(* A result that had a stamp when the turn took it carries that stamp in   *)
(* every piece of it, through rewrites and recovery.                       *)
StampIsBirth ==
  \A i \in 1..Len(log) :
    /\ log[i].kind = "piece"
    /\ log[i].piece.call \in stampedAt
    => log[i].piece.stamp = birthOf[log[i].piece.call]

(* Witnesses: each must be violated, which shows the state is reachable. *)
NeverSuperseded == supersedes = 0
NeverCommittedWhole == ~(committed /\ Len(final) = Cardinality(Calls) /\ builds >= 3)
NeverCommittedAfterCut == ~(committed /\ cut > 0 /\ Len(final) > 0)
NeverCommittedAfterRecovery == ~(committed /\ recovered /\ Len(final) > 0)
MissedPathsNeverParse == anyParsed = 0
=============================================================================
