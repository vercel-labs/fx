--------------------------- MODULE UiStreamOrder ---------------------------
(***************************************************************************)
(* The order a viewer sees a session's UI lines in (`sdk/durable.js`       *)
(* `uiWriter` and the `ui.write` of `createWorldBackend`), on a World      *)
(* whose chunks can land out of order.                                      *)
(*                                                                         *)
(* The writer pushes lines one at a time. When no write is in flight it    *)
(* hands the World every line pushed so far, in one call: a call of one    *)
(* chunk is `write`, a call of several is `writeMulti`. Lines pushed while *)
(* a call is in flight wait for the next one, so at most one call is in    *)
(* flight. Line i is chunk i, and a chunk's id order is the order it was   *)
(* written in.                                                             *)
(*                                                                         *)
(* A World lands the chunks of one call in some order. world-local 5.1.1   *)
(* writes a writeMulti call's chunk files in parallel (`Parallel`: any     *)
(* chunk of the call may land next); world-local 5.2 and later, and        *)
(* Vercel's World, land them in order (`InOrder`). A live reader lists the *)
(* stream's chunks, then reads what it listed, lowest id first. world-     *)
(* local's reader (`Exists`) lists every chunk that is on disk and not yet *)
(* delivered, so a chunk with a higher id than one still on its way can be *)
(* read first; a reader that lists only chunks whose lower ids are all on  *)
(* disk (`IdOrder`) cannot. The reader's other way to see a chunk, the     *)
(* in-process event a write emits, only delivers a chunk after the chunks  *)
(* before it, so it never reorders and is left out.                        *)
(*                                                                         *)
(* WritePolicy is what libfx does: `Multi` sends all waiting lines in one  *)
(* call, as libfx did on every World, and `OneByOne` sends one chunk per   *)
(* call, as libfx does on local(). The configs say which combination each  *)
(* World is:                                                               *)
(*   UiStreamOrder                OneByOne, Parallel, Exists: local() now  *)
(*   UiStreamOrder-InOrderLanding Multi, InOrder, Exists: Vercel's World   *)
(*   UiStreamOrder-IdOrderReader  Multi, Parallel, IdOrder: a World whose  *)
(*                                reader waits for lower ids               *)
(*   UiStreamOrder-ParallelMulti  Multi, Parallel, Exists: local() before  *)
(*                                the fix, which must fail                 *)
(*                                DeliveredInOrder                         *)
(*   UiStreamOrder-ParallelMultiGap  the same, which must also fail        *)
(*                                LandedIsPrefix: a crash mid-call leaves  *)
(*                                a chunk on disk past one that is missing *)
(*                                                                         *)
(* tests/tla/drivers/sdk/ui-order.ts runs the real code with one slow      *)
(* chunk write and has TLC check what it did against this model through    *)
(* UiStreamOrderTrace.tla.                                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Lines,        \* how many lines the writer pushes in the scenario
    WritePolicy,  \* "OneByOne" or "Multi"
    WorldLands,   \* "Parallel" or "InOrder"
    Reader        \* "Exists" or "IdOrder"

ASSUME Lines \in Nat /\ Lines >= 1
ASSUME WritePolicy \in {"OneByOne", "Multi"}
ASSUME WorldLands \in {"Parallel", "InOrder"}
ASSUME Reader \in {"Exists", "IdOrder"}

VARIABLES
    pushed,   \* lines the writer has produced
    sent,     \* lines handed to the World, in calls
    busy,     \* a call is in flight
    call,     \* the chunks of the call in flight that have not landed
    landed,   \* the chunks on disk
    snap,     \* the chunks the reader has listed and not yet read
    got       \* the chunk ids the reader delivered, in delivery order

vars == <<pushed, sent, busy, call, landed, snap, got>>

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Delivered == {got[i] : i \in 1..Len(got)}

TypeOK ==
    /\ pushed \in 0..Lines
    /\ sent \in 0..Lines
    /\ sent <= pushed
    /\ busy \in BOOLEAN
    /\ call \subseteq 1..Lines
    /\ landed \subseteq 1..Lines
    /\ snap \subseteq 1..Lines
    /\ got \in Seq(1..Lines)

Init ==
    /\ pushed = 0
    /\ sent = 0
    /\ busy = FALSE
    /\ call = {}
    /\ landed = {}
    /\ snap = {}
    /\ got = <<>>

\* The turn produces a line.
Push ==
    /\ pushed < Lines
    /\ pushed' = pushed + 1
    /\ UNCHANGED <<sent, busy, call, landed, snap, got>>

\* The writer hands the World the next `k` waiting lines in one call.
Issue(k) ==
    /\ ~busy
    /\ sent < pushed
    /\ k \in 1..(pushed - sent)
    /\ WritePolicy = "OneByOne" => k = 1
    /\ sent' = sent + k
    /\ busy' = TRUE
    /\ call' = (sent + 1)..(sent + k)
    /\ UNCHANGED <<pushed, landed, snap, got>>

\* The World puts one chunk of the call on disk.
Land(c) ==
    /\ c \in call
    /\ WorldLands = "InOrder" => c = Min(call)
    /\ landed' = landed \cup {c}
    /\ call' = call \ {c}
    /\ UNCHANGED <<pushed, sent, busy, snap, got>>

\* The call returns once every chunk of it landed.
Return ==
    /\ busy
    /\ call = {}
    /\ busy' = FALSE
    /\ UNCHANGED <<pushed, sent, call, landed, snap, got>>

\* What the reader's listing holds: every undelivered chunk on disk, or only
\* those with all lower ids on disk too.
Listable ==
    IF Reader = "Exists"
        THEN landed \ Delivered
        ELSE {c \in landed \ Delivered : \A d \in 1..(c - 1) : d \in landed}

List ==
    /\ snap = {}
    /\ Listable # {}
    /\ snap' = Listable
    /\ UNCHANGED <<pushed, sent, busy, call, landed, got>>

\* The reader takes the lowest chunk it listed, unless it has delivered it
\* already.
Read ==
    /\ snap # {}
    /\ LET c == Min(snap)
       IN /\ snap' = snap \ {c}
          /\ got' = IF c \in Delivered THEN got ELSE Append(got, c)
    /\ UNCHANGED <<pushed, sent, busy, call, landed>>

\* Every line is delivered.
Done ==
    /\ Len(got) = Lines
    /\ UNCHANGED vars

Next ==
    \/ Push
    \/ \E k \in 1..Lines : Issue(k)
    \/ \E c \in 1..Lines : Land(c)
    \/ Return
    \/ List
    \/ Read
    \/ Done

Spec == Init /\ [][Next]_vars

\* The viewer sees line 1, then line 2, then line 3, and so on.
DeliveredInOrder == \A i \in 1..Len(got) : got[i] = i

\* The chunks on disk are lines 1 to n with none missing, so a crash leaves a
\* stream that is a prefix of the turn.
LandedIsPrefix == \A c \in landed : \A d \in 1..(c - 1) : d \in landed

\* Violated when every line can be delivered: the model is not stuck.
NotAllDelivered == Len(got) < Lines
=============================================================================
