------------------------------ MODULE ProviderCompaction ------------------------------
(***************************************************************************)
(* Compaction for providers that bind each reply's reasoning to everything *)
(* sent before it: Claude 4.6 and later and OpenAI GPT-6 and later         *)
(* (`src/core/compactor/compactor.zig`, the provider path).                *)
(*                                                                         *)
(* A session holds items: a user message, a step (one reply with its       *)
(* reasoning, written by one model), the provider's own summary block, or  *)
(* fx's own summary. Each request sends the session to the current model.  *)
(* fx sends a block only to the model that wrote it and fx's exact summary *)
(* of the same turns to any other model, and another model's steps go      *)
(* without their reasoning. A provider reads its own block as the items it *)
(* stands for.                                                             *)
(*                                                                         *)
(* A compaction keeps up to Keep of the newest turns, the running one      *)
(* included, after the block (KeepCompaction). When the running turn alone *)
(* does not fit, the block takes everything fx was about to send, and the  *)
(* running turn's first message follows it again (WholeCompaction). When   *)
(* the provider fails, fx writes its own summary and keeps no turn or step *)
(* after it, only the running turn's first message. A block one model      *)
(* writes keeps another model's steps after it only as text: that model    *)
(* reads fx's summary in place of the block, so the steps' reasoning would *)
(* follow a prefix it was never written after. A crash before the commit   *)
(* saves nothing, so the resumed session sends what it sent before.        *)
(*                                                                         *)
(* NoDroppedReasoning: every step the current model reads with its         *)
(* reasoning sits after exactly what that model read before it when it     *)
(* wrote the reasoning, so no provider drops it.                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  MaxTurns,        \* turns in one behavior
  MaxSteps,        \* replies in one turn
  Keep,            \* newest turns a compaction keeps after the provider's block
  MaxCompactions,
  Models,          \* models the session can switch between
  Provider,        \* TRUE: fx asks the provider for its block; FALSE: today
  Bug              \* "none" or a planted defect, see check.sh

Item(k, n, m, cov) == [k |-> k, n |-> n, m |-> m, covers |-> cov]
User(t) == Item("user", t, "none", <<>>)
Step(s, m) == Item("step", s, m, <<>>)
FxSummary(c) == Item("fx", c, "none", <<>>)
Block(c, m, cov) == Item("block", c, m, cov)
Note == Item("note", 0, "none", <<>>)

\* The kept items after model m's block: another model's steps lose their
\* reasoning and stay as their text.
KeptAfterBlock(s, m) ==
  [i \in 1..Len(s) |->
     IF s[i].k = "step" /\ s[i].m # m /\ Bug # "keeps_foreign_reasoning"
     THEN Item("text", s[i].n, s[i].m, <<>>) ELSE s[i]]

\* What fx sends for a saved item in a request to model m.
Wire(item, m) ==
  CASE item.k = "block" /\ (item.m = m \/ Bug = "switch_sends_block") -> item
    [] item.k = "block" -> FxSummary(item.n)
    [] item.k = "step" /\ item.m # m -> Item("text", item.n, item.m, <<>>)
    [] OTHER -> item

\* What model m's provider reads a sent item as.
Read(w, m) ==
  CASE w.k = "block" /\ w.m = m -> w.covers
    [] w.k = "block" -> << [a |-> "unreadable", n |-> w.n] >>
    [] OTHER -> << [a |-> w.k, n |-> w.n] >>

RECURSIVE Canon(_, _)
Canon(s, m) == IF s = <<>> THEN <<>> ELSE Read(Wire(Head(s), m), m) \o Canon(Tail(s), m)

None == [state |-> "none", mode |-> "none", older |-> <<>>, kept |-> <<>>]

VARIABLES
  ctx,          \* the saved session
  model,        \* the model every request goes to
  bound,        \* bound[s]: what step s's model read before its reasoning
  nextTurn,
  nextStep,
  open,         \* the running turn, 0 between turns
  steps,        \* replies the running turn has so far
  pending,      \* the compaction in flight, held in memory only
  compactions,
  last          \* the action that led here, for the drivers

vars == <<ctx, model, bound, nextTurn, nextStep, open, steps, pending, compactions, last>>

Init ==
  /\ ctx = <<>>
  /\ model \in Models
  /\ bound = [s \in 1..(MaxTurns * MaxSteps) |-> <<>>]
  /\ nextTurn = 1
  /\ nextStep = 1
  /\ open = 0
  /\ steps = 0
  /\ pending = None
  /\ compactions = 0
  /\ last = "Init"

Idle == pending.state = "none"

NewTurn ==
  /\ Idle /\ open = 0 /\ nextTurn <= MaxTurns
  /\ ctx' = Append(ctx, User(nextTurn))
  /\ open' = nextTurn
  /\ nextTurn' = nextTurn + 1
  /\ steps' = 0
  /\ last' = "NewTurn"
  /\ UNCHANGED <<model, bound, nextStep, pending, compactions>>

\* One request and its reply: the reasoning is written after all of it.
AddStep ==
  /\ Idle /\ open # 0 /\ steps < MaxSteps
  /\ bound' = [bound EXCEPT ![nextStep] = Canon(ctx, model)]
  /\ ctx' = Append(ctx, Step(nextStep, model))
  /\ nextStep' = nextStep + 1
  /\ steps' = steps + 1
  /\ last' = "AddStep"
  /\ UNCHANGED <<model, nextTurn, open, pending, compactions>>

EndTurn ==
  /\ Idle /\ open # 0 /\ steps > 0
  /\ open' = 0
  /\ last' = "EndTurn"
  /\ UNCHANGED <<ctx, model, bound, nextTurn, nextStep, steps, pending, compactions>>

\* The turn ends without its final reply: fx was stopped or crashed. fx's
\* interrupted-turn projection changes only the end of what it sends, which
\* no finished request has sent: a turn with no step after its message
\* leaves the conversation, and otherwise its last step goes as text,
\* followed by two notes that say the turn ended early.
Abort ==
  /\ Idle /\ open # 0
  /\ ctx' = LET tail == ctx[Len(ctx)] IN
            IF tail.k = "user" THEN SubSeq(ctx, 1, Len(ctx) - 1)
            ELSE SubSeq(ctx, 1, Len(ctx) - 1) \o << Item("text", tail.n, tail.m, <<>>), Note, Note >>
  /\ open' = 0
  /\ last' = "Abort"
  /\ UNCHANGED <<model, bound, nextTurn, nextStep, steps, pending, compactions>>

SwitchModel ==
  /\ Idle /\ open = 0
  /\ \E m \in Models \ {model} : model' = m
  /\ last' = "SwitchModel"
  /\ UNCHANGED <<ctx, bound, nextTurn, nextStep, open, steps, pending, compactions>>

\* The window keeps the turns from a user message on (never part of a turn),
\* at most Keep of them, or nothing between turns, and sends the older items
\* exactly as saved, with the provider's compaction option.
KeepCompaction ==
  /\ Idle /\ compactions < MaxCompactions
  /\ \E i \in 2..(Len(ctx) + 1) :
       /\ IF i = Len(ctx) + 1 THEN open = 0 ELSE ctx[i].k = "user"
       /\ Cardinality({j \in i..Len(ctx) : ctx[j].k = "user"}) <= Keep
       /\ pending' = [state |-> "asked", mode |-> "keep",
                      older |-> SubSeq(ctx, 1, i - 1), kept |-> SubSeq(ctx, i, Len(ctx))]
  /\ last' = "KeepCompaction"
  /\ UNCHANGED <<ctx, model, bound, nextTurn, nextStep, open, steps, compactions>>

\* The running turn alone does not fit: the provider gets everything fx was
\* about to send, and the turn's first message follows the block.
WholeCompaction ==
  /\ Idle /\ compactions < MaxCompactions /\ open # 0 /\ steps > 0
  /\ pending' = [state |-> "asked", mode |-> "whole", older |-> ctx, kept |-> << User(open) >>]
  /\ last' = "WholeCompaction"
  /\ UNCHANGED <<ctx, model, bound, nextTurn, nextStep, open, steps, compactions>>

\* The provider answers with its block, or fails: down, refused, an empty or
\* wrong-kind reply, an oversized block, a cut-off stream. Without the
\* provider path every compaction is fx's.
Reply ==
  /\ pending.state = "asked"
  /\ \E s \in (IF Provider THEN {"block", "failed"} ELSE {"failed"}) :
       pending' = [pending EXCEPT !.state = s]
  /\ last' = "Reply"
  /\ UNCHANGED <<ctx, model, bound, nextTurn, nextStep, open, steps, compactions>>

\* Where the running turn starts in the saved session.
OpenFrom ==
  IF open = 0 \/ ~\E i \in 1..Len(ctx) : ctx[i] = User(open) THEN Len(ctx) + 1
  ELSE CHOOSE i \in 1..Len(ctx) : ctx[i] = User(open) /\ \A j \in (i + 1)..Len(ctx) : ctx[j] # User(open)

OpenMessage == IF open = 0 THEN <<>> ELSE << User(open) >>

\* One commit replaces the older items: with the provider's block and the kept
\* items unchanged, or with fx's summary and only the running turn's message.
Commit ==
  /\ pending.state \in {"block", "failed"}
  /\ ctx' =
       IF pending.state = "block" THEN
         << Block(compactions + 1, model, Canon(pending.older, model)) >> \o
         (IF pending.mode = "whole" /\ Bug = "whole_forgets_task" THEN <<>> ELSE KeptAfterBlock(pending.kept, model))
       ELSE
         << FxSummary(compactions + 1) >> \o
         (IF Bug = "fallback_keeps" THEN
            (IF pending.mode = "whole" THEN SubSeq(ctx, OpenFrom, Len(ctx)) ELSE pending.kept)
          ELSE OpenMessage)
  /\ pending' = None
  /\ compactions' = compactions + 1
  /\ last' = "Commit"
  /\ UNCHANGED <<model, bound, nextTurn, nextStep, open, steps>>

\* fx exits before the commit: nothing was saved.
Crash ==
  /\ pending.state # "none"
  /\ pending' = None
  /\ last' = "Crash"
  /\ UNCHANGED <<ctx, model, bound, nextTurn, nextStep, open, steps, compactions>>

Next ==
  \/ NewTurn \/ AddStep \/ EndTurn \/ Abort \/ SwitchModel
  \/ KeepCompaction \/ WholeCompaction \/ Reply \/ Commit \/ Crash

Spec == Init /\ [][Next]_vars /\ WF_vars(Reply) /\ WF_vars(Commit)

\* The behaviors tests/tla/drivers/compaction/provider.test.ts forces on a
\* built fx. A compaction that keeps turns starts at a turn's first request
\* and cuts right after a step, which the driver makes large. A whole-turn
\* compaction follows a step the driver makes large. A turn ends on its final
\* reply. A crash happens while the provider writes its block, and that turn
\* then ends.
DriveNext ==
  \/ NewTurn
  \/ AddStep /\ last # "Crash"
  \/ EndTurn /\ last = "AddStep"
  \/ Abort /\ last = "Crash"
  \/ SwitchModel
  \/ KeepCompaction /\ last = "NewTurn" /\ open # 0 /\ steps = 0
       /\ pending'.older # <<>> /\ pending'.older[Len(pending'.older)].k = "step"
  \/ WholeCompaction /\ last = "AddStep"
  \/ Reply
  \/ Commit
  \/ Crash /\ pending.state = "asked"

DriveSpec == Init /\ [][DriveNext]_vars

TypeOK ==
  /\ model \in Models
  /\ nextTurn \in 1..(MaxTurns + 1)
  /\ nextStep \in 1..(MaxTurns * MaxSteps + 1)
  /\ open \in 0..MaxTurns
  /\ compactions \in 0..MaxCompactions
  /\ pending.state \in {"none", "asked", "block", "failed"}

NoDroppedReasoning ==
  \A i \in 1..Len(ctx) :
    (ctx[i].k = "step" /\ ctx[i].m = model) =>
      Canon(SubSeq(ctx, 1, i - 1), model) = bound[ctx[i].n]

\* No request sends a block to a model that did not write it.
Readable ==
  \A i \in 1..Len(ctx) : LET w == Wire(ctx[i], model) IN w.k = "block" => w.m = model

\* The running turn's first message stays in what fx sends.
TaskKept ==
  (open # 0 /\ pending.state = "none") => \E i \in 1..Len(ctx) : ctx[i] = User(open)

\* Every compaction that starts ends: committed, or dropped by a crash.
CompactionFinishes == (pending.state # "none") ~> (pending.state = "none")
=============================================================================
