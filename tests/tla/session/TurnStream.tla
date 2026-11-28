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
(*                agent's view; the turn the log saves keeps them (D87)    *)
(*   Recovery     fx stops mid-turn; resuming rebuilds the turn's messages *)
(*                from its recovery checkpoint and streams a new turn      *)
(*   Faults       a later rebuild gives a streamed result other content,   *)
(*                or loses one. A turn written afresh after a compaction   *)
(*                cut it holds only the agent's view: resume finds a cut   *)
(*                by its turn's number, which the copy does not keep       *)
(*                (`TurnView`)                                             *)
(*   FailedCommits a commit fails and the host goes on to its next turn,   *)
(*                which marks the open turn stale (D98): the next write    *)
(*                closes it as superseded and writes the turn afresh       *)
(*   Continues    a Ctrl+G yield, a crash, or a closed window stops the open  *)
(*                turn; the turn that continues it writes only the pieces    *)
(*                past the stopped ones, or a full copy when those pieces no *)
(*                longer stand (`Continue`)                                  *)
(*                                                                           *)
(* A new prompt after a stop, which the product shows as a stopped turn, is  *)
(* outside this model, because it models one turn.                           *)
(*                                                                         *)
(* Mutant selects the design. "none" is fx as it is; "restamp" is fx       *)
(* before results kept their stamps; "cut_view" is fx before the log saved *)
(* the results a compaction took out of the agent's view, so the rebuild   *)
(* no longer lined up; "copy_whole" is fx before a copy written after a    *)
(* cut kept to the agent's view; the rest are planted bugs.                *)
(* TurnStreamTrace.tla replays runs of the real binary through this model. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Calls, MaxBuilds, MissedPaths, Compactions, Recovery, Faults,
          FailedCommits, Continues, Mutant

Mutants == {"none", "restamp", "cut_view", "copy_whole", "lose_on_recover", "share_stamp",
            "bytes_only", "loose_compare", "mix_on_mismatch", "prefix_only",
            "continue_stale", "continue_copies", "reader_drops_yielded",
            "reader_drops_crashed"}

ASSUME Mutant \in Mutants
ASSUME MaxBuilds \in Nat
ASSUME {MissedPaths, Compactions, Recovery, Faults, FailedCommits, Continues} \subseteq BOOLEAN

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
  supersedes, \* turns closed because their stream differed
  unexplained,\* of those, closed with no fault and no compaction behind it
  reparsed,   \* streamed pieces of stamped results samePiece had to parse
  anyParsed,  \* streamed pieces of any result samePiece had to parse
  last,       \* what the last stream or commit decided
  stale,      \* the open turn is one a failed commit left behind (D98)
  failedAt,   \* the log's length when a failed commit left its turn, or 0
  base,       \* the stopped turn's pieces, as its stream held them when it stopped
  yielded,    \* the log ends with a stop (a yield, a crash, or a close), and no turn has continued it yet
  copyView    \* the open or committed turn is a copy written after a supersede
              \* once a compaction cut it (`open_cut_copy`)

vars == <<done, cut, changed, dropped, builds, streamed, open, log, committed,
          final, birthOf, stampedAt, recovered, supersedes,
          unexplained, reparsed, anyParsed, last, stale, failedAt, base, yielded,
          copyView>>

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

(* The results the turn the log saves holds, in order: a compaction takes   *)
(* none out (`TurnFinalizationGuard.savedExecution`, D87).                 *)
Saved == SelectSeq(done, LAMBDA r : r.call \notin dropped)

Rebuilt == IF Mutant = "cut_view" THEN View ELSE Saved

(* A compaction cut results out of the agent's view, so fx gives the       *)
(* adapter both views (`saved_execution`). The "cut_view" design had one.  *)
Cuts == cut > 0 /\ Mutant # "cut_view"

(* `buildNormalExecutionMemory`: a result keeps its message's stamp. *)
StampFor(r, n) ==
  IF r.stamped /\ Mutant # "restamp" THEN r.birth ELSE Stamp(n, r.call)

(* Rebuild number n of the results v. *)
FreshOf(v, n) ==
  [i \in 1..Len(v) |->
     Piece(v[i].call, IF v[i].call \in changed THEN 1 ELSE 0, StampFor(v[i], n))]

Fresh(n) == FreshOf(Rebuilt, n)

KeepsView == Mutant # "copy_whole"

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

(* Whether the next write continues the open turn: a stale one is closed   *)
(* as superseded first (`streamedPrefix`, `openTurnLocked`).               *)
Live == open /\ (~stale \/ Mutant = "continue_stale")
Closing == open /\ ~Live

After(b) == SubSeq(b, Len(streamed) + 1, Len(b))
NewPieces(b) == IF Len(streamed) <= Len(b) THEN After(b) ELSE <<>>

Held(b) ==
  IF ~Live THEN b
  ELSE IF Stands(b) \/ Mixes THEN streamed \o NewPieces(b)
  ELSE b

Lines(b) ==
  IF Closing THEN <<Superseded>> \o AsLines(b)
  ELSE IF ~open THEN AsLines(b)
  ELSE IF Stands(b) \/ Mixes THEN AsLines(NewPieces(b))
  ELSE <<Superseded>> \o AsLines(b)

(* Whether a write that decided on b closes the open turn as superseded. *)
Supersedes(b) == Closing \/ (Live /\ ~Stands(b) /\ ~Mixes)

(* `TurnView`: what write n decides on. A copy of a turn with a cut keeps   *)
(* to the agent's view.                                                    *)
First(n) == IF copyView /\ Cuts /\ KeepsView THEN FreshOf(View, n) ELSE Fresh(n)

(* Whether the write that decided on b starts a copy of a turn with a cut. *)
CopiesCut(b) == Cuts /\ Supersedes(b)

(* What write n puts in the log after deciding on b: a copy of a turn with *)
(* a cut holds the agent's view.                                           *)
Written(b, n) == IF CopiesCut(b) /\ KeepsView THEN FreshOf(View, n) ELSE b

(* The log lines and the open turn's pieces after a write that decided on  *)
(* b and wrote w.                                                          *)
WriteLines(b, w) == IF Supersedes(b) THEN <<Superseded>> \o AsLines(w) ELSE Lines(b)
HeldAfter(b, w) == IF Supersedes(b) THEN w ELSE Held(b)
CopyAfter(b) ==
  IF CopiesCut(b) THEN TRUE
  ELSE IF ~open \/ Supersedes(b) THEN FALSE
  ELSE copyView

(* A line that ends a turn, unless the next line is an extends marker. The   *)
(* planted `reader_drops_yielded` reader ends the turn at every              *)
(* interruption; `reader_drops_crashed` (`src/core/session/`                 *)
(* `session_adapter.zig` `replay`) ends it at an interruption with no yield  *)
(* marker right before it, even when an extends marker follows.              *)
Ends(i) ==
  /\ log[i].kind \in {"superseded", "interrupted"}
  /\ (Mutant = "reader_drops_yielded"
      \/ (Mutant = "reader_drops_crashed" /\ log[i].kind = "interrupted"
          /\ (i = 1 \/ log[i - 1].kind # "yielded"))
      \/ IF i = Len(log) THEN TRUE ELSE log[i + 1].kind # "extends")

(* The rebuild b still starts with the stopped pieces, compared as           *)
(* `streamedPrefix` compares them. *)
Extends(b) ==
  /\ Len(base) <= Len(b)
  /\ \A i \in 1..Len(base) : SamePiece(base[i], b[i])

Faultless == changed \cup dropped = {}

(* The streamed pieces whose bytes the rebuild changed but samePiece let   *)
(* stand, and those of them that answer a result with a stamp.             *)
Parsed(b) ==
  {i \in 1..Len(streamed) : i <= Len(b) /\ ~SameBytes(streamed[i], b[i])}
StampedParsed(b) ==
  {i \in Parsed(b) : \E r \in Range(done) : r.call = b[i].call /\ r.stamped}

(* A stale turn's supersede is explained by its failed commit, so it is    *)
(* counted apart from a stream that differed. A copy that keeps to the     *)
(* agent's view differs from it after each later cut, which the copy      *)
(* explains.                                                               *)
Decide(b, phase) ==
  LET stands     == ~Live \/ Stands(b)
      supersede  == ~stands /\ ~Mixes
      count      == IF Live /\ Stands(b) THEN Cardinality(Parsed(b)) ELSE 0
      stampedOne == IF Live /\ Stands(b) THEN Cardinality(StampedParsed(b)) ELSE 0
  IN /\ supersedes' = supersedes + (IF supersede THEN 1 ELSE 0)
     /\ unexplained' = unexplained + (IF supersede /\ Faultless /\ ~copyView THEN 1 ELSE 0)
     /\ reparsed' = reparsed + stampedOne
     /\ anyParsed' = anyParsed + count
     /\ last' = Decision(phase, stands, Len(b), count)

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
  /\ supersedes = 0
  /\ unexplained = 0
  /\ reparsed = 0
  /\ anyParsed = 0
  /\ last = Decision(None, TRUE, 0, 0)
  /\ stale = FALSE
  /\ failedAt = 0
  /\ base = <<>>
  /\ yielded = FALSE
  /\ copyView = FALSE

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
                 final, recovered, supersedes, unexplained, reparsed,
                 anyParsed, last, stale, failedAt, base, yielded, copyView>>

(* Compaction takes the first k results of the view out of it. *)
Compact(k) ==
  /\ Compactions
  /\ ~committed
  /\ k \in 1..(Len(done) - cut)
  /\ cut' = cut + k
  /\ UNCHANGED <<done, changed, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, supersedes, unexplained,
                 reparsed, anyParsed, last, stale, failedAt, base, yielded,
                 copyView>>

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
  /\ stale' = FALSE
  /\ copyView' = FALSE
  /\ UNCHANGED <<changed, builds, committed, final, birthOf, stampedAt,
                 supersedes, unexplained, reparsed, anyParsed, last, failedAt,
                 base, yielded>>

(* A later rebuild gives a streamed result other content. *)
Change(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed) \cup Range(base)}
  /\ changed' = {c}
  /\ UNCHANGED <<done, cut, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, supersedes,
                 unexplained, reparsed, anyParsed, last, stale, failedAt,
                 base, yielded, copyView>>

(* A later rebuild no longer has a streamed result, so the rest shift. *)
Drop(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed) \cup Range(base)}
  /\ dropped' = {c}
  /\ UNCHANGED <<done, cut, changed, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, supersedes,
                 unexplained, reparsed, anyParsed, last, stale, failedAt,
                 base, yielded, copyView>>

(* `appendProgress`: the turn so far, before the next model request. *)
Stream ==
  /\ ~committed
  /\ ~yielded
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == First(builds + 1)
         w == Written(b, builds + 1)
     IN /\ log' = log \o WriteLines(b, w)
        /\ streamed' = HeldAfter(b, w)
        /\ Decide(b, "stream")
        /\ copyView' = CopyAfter(b)
  /\ open' = TRUE
  /\ stale' = (Mutant = "continue_stale" /\ stale)
  /\ UNCHANGED <<done, cut, changed, dropped, committed, final, birthOf,
                 stampedAt, recovered, failedAt, base, yielded>>

(* `commitTurn`: the finished turn, its end in the same batch. *)
Commit ==
  /\ ~committed
  /\ ~yielded
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == First(builds + 1)
         w == Written(b, builds + 1)
     IN /\ log' = log \o WriteLines(b, w) \o <<End>>
        /\ Decide(b, "commit")
        /\ final' = w
        \* Kept past the end, so the properties know the turn is a copy.
        /\ copyView' = CopyAfter(b)
  /\ streamed' = <<>>
  /\ committed' = TRUE
  /\ open' = FALSE
  /\ stale' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, birthOf, stampedAt, recovered, failedAt, base, yielded>>

(* A commit fails before its batch reaches the log, and the host goes on:  *)
(* `beginCaptureTurn` drops the failed turn's captures and, since the open *)
(* turn holds a start capture, marks it stale. A retry with the same token *)
(* is `Commit` itself and supersedes nothing.                              *)
FailCommit ==
  /\ FailedCommits
  /\ ~committed
  /\ open
  /\ ~stale
  /\ failedAt = 0
  /\ stale' = TRUE
  /\ failedAt' = Len(log)
  /\ UNCHANGED <<done, cut, changed, dropped, builds, streamed, open, log,
                 committed, final, birthOf, stampedAt, recovered,
                 supersedes, unexplained, reparsed, anyParsed, last, base, yielded,
                 copyView>>

(* Ctrl+G stops the open turn at a boundary (`markYielded`): its log gets the *)
(* yield marker and an interruption, and nothing more is streamed.           *)
Yield ==
  /\ Continues
  /\ open
  /\ ~stale
  /\ ~committed
  /\ log' = log \o <<Line("yielded", NoPiece), Interrupted>>
  /\ base' = streamed
  /\ yielded' = TRUE
  /\ open' = FALSE
  /\ streamed' = <<>>
  /\ copyView' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, builds, committed, final, birthOf,
                 stampedAt, recovered, supersedes, unexplained, reparsed,
                 anyParsed, last, stale, failedAt>>

(* fx dies or its window closes at a boundary (`src/core/session_manager/`   *)
(* ends the open turn `crash` or `closed`): its log gets only an             *)
(* interruption, with no yield marker, and nothing more is streamed.         *)
Crash ==
  /\ Continues
  /\ open
  /\ ~stale
  /\ ~committed
  /\ log' = log \o <<Interrupted>>
  /\ base' = streamed
  /\ yielded' = TRUE
  /\ open' = FALSE
  /\ streamed' = <<>>
  /\ copyView' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, builds, committed, final, birthOf,
                 stampedAt, recovered, supersedes, unexplained, reparsed,
                 anyParsed, last, stale, failedAt>>

(* The continuing turn opens with one rebuild. When the stopped pieces still  *)
(* stand as its prefix, the log gets an extends marker and only the pieces    *)
(* past them, and the open turn holds all of them. Otherwise the log gets a   *)
(* plain marker and a full copy, and the reader drops the stopped copy.       *)
Continue ==
  /\ Continues
  /\ yielded
  /\ ~committed
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == Fresh(builds + 1)
         ext == SubSeq(b, Len(base) + 1, Len(b))
     IN /\ log' = IF Mutant = "continue_copies"
                  THEN log \o <<Line("extends", NoPiece)>> \o AsLines(b)
                  ELSE IF Extends(b)
                  THEN log \o <<Line("extends", NoPiece)>> \o AsLines(ext)
                  ELSE log \o <<Line("continued", NoPiece)>> \o AsLines(b)
        /\ streamed' = IF Mutant # "continue_copies" /\ Extends(b)
                       THEN base \o ext
                       ELSE b
  /\ open' = TRUE
  /\ yielded' = FALSE
  /\ base' = <<>>
  /\ stale' = FALSE
  /\ copyView' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, committed, final, birthOf, stampedAt,
                 recovered, supersedes, unexplained, reparsed, anyParsed,
                 last, failedAt>>

Next ==
  \/ \E c \in Calls, stamped \in BOOLEAN : RunTool(c, stamped)
  \/ \E c \in Calls : Change(c) \/ Drop(c)
  \/ \E k \in 1..Cardinality(Calls) : Compact(k)
  \/ Recover
  \/ Stream
  \/ Commit
  \/ FailCommit
  \/ Yield
  \/ Crash
  \/ Continue

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The lines after the last superseded or interrupted marker hold the live *)
(* turn.                                                                   *)
LastMark ==
  LET marks == {i \in 1..Len(log) : Ends(i)}
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
       \/ log[i].kind \in {"superseded", "interrupted", "end", "yielded", "extends", "continued"}
            /\ log[i].piece = NoPiece
  /\ stampedAt \subseteq Calls
  /\ {supersedes, unexplained, reparsed, anyParsed, failedAt} \subseteq Nat
  /\ stale \in BOOLEAN
  /\ stale => open
  /\ base \in Seq(Pieces)
  /\ yielded \in BOOLEAN
  /\ copyView \in BOOLEAN
  /\ yielded => ~open
  /\ ~yielded => base = <<>>

(* The committed turn holds the final rebuild's calls and content, and     *)
(* nothing a stale stream left.                                            *)
CommitIsFinal == committed => Content(LiveTurn) = Content(final)

(* When every result kept its stamp, the commit encodes exactly the bytes  *)
(* the log holds.                                                          *)
CommitIsWritten == committed /\ AllStamped => LiveTurn = final

(* A stream is superseded only when a rebuild really differs from it; a    *)
(* compaction never makes it differ.                                       *)
SupersedeExplained == unexplained = 0

(* The committed turn holds every result the turn ran, those a compaction  *)
(* took out of the agent's view too, except one a fault dropped, unless it *)
(* is a copy written after a supersede once a compaction cut it.           *)
LogKeepsCutResults ==
  committed /\ ~copyView => LiveCalls = [i \in 1..Len(Saved) |-> Saved[i].call]

(* Resume finds a cut by its turn's number, and a copy written after a     *)
(* supersede has a new one, so resume cannot trim it. Such a copy holds    *)
(* only the agent's view, so the model is never sent the results the       *)
(* compaction summarized; the transcript loses them.                       *)
CopyHoldsView ==
  committed /\ copyView => LiveCalls = [i \in 1..Len(View) |-> View[i].call]

(* No rebuild needs samePiece's parser for a result that kept its stamp. *)
NoReparseOfStamped == reparsed = 0

(* A turn a failed commit left behind is never continued: every piece      *)
(* written after the failure follows a superseded or interrupted mark.     *)
StaleTurnNeverContinues ==
  failedAt > 0 =>
    \A i \in (failedAt + 1)..Len(log) :
      log[i].kind = "piece" =>
        \E j \in (failedAt + 1)..(i - 1) : log[j].kind \in {"superseded", "interrupted"}

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

(* The read-back shows each call's piece once. *)
ReadsEachPieceOnce ==
  \A i, j \in 1..Len(LiveTurn) : i # j => LiveTurn[i].call # LiveTurn[j].call

ReadCalls == {LiveTurn[i].call : i \in 1..Len(LiveTurn)}

(* The read-back shows every piece the open turn holds, and every piece of    *)
(* the committed rebuild. `done` alone would not do: a result may run before  *)
(* it streams. *)
ReadsNoneLost ==
  /\ open => \A p \in Range(streamed) : p.call \in ReadCalls
  /\ committed => \A p \in Range(final) : p.call \in ReadCalls

(* Witnesses: each must be violated, which shows the state is reachable. *)
NeverSuperseded == supersedes = 0
NeverCommittedWhole == ~(committed /\ Len(final) = Cardinality(Calls) /\ builds >= 3)
NeverCommittedAfterCut == ~(committed /\ cut > 0 /\ Len(final) > 0)
NeverCommittedAfterRecovery == ~(committed /\ recovered /\ Len(final) > 0)
NeverCommittedAfterFailure == ~(committed /\ failedAt > 0)
NeverCopiedAfterCut == ~(committed /\ copyView /\ Len(View) > 0)
MissedPathsNeverParse == anyParsed = 0
NeverExtends == ~(\E i \in 1..Len(log) : log[i].kind = "extends")
NeverCopiedAfterYield == ~(\E i \in 1..Len(log) : log[i].kind = "continued")
=============================================================================
