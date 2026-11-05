---- MODULE FullDetailOrder ----
\* The order Ctrl+O shows one turn in, live and after a resume.
\*
\* A turn is a prompt and then model steps. Each step's model call may fail
\* and be retried (a failed attempt), then succeeds: its text streams, the
\* call settles (its record: time, model, tokens, gen ID), and every step but
\* the last starts tools. The worker sends these as events in the order they
\* happen; the app shows them in that order (the live view). The session
\* saves the turn so far at moments the model leaves free; fx may crash at
\* any moment before the turn commits. A resume rebuilds the view from what
\* was saved: per step, how many attempts failed, whether its text, its
\* record and its tools were saved.
\*
\* The design: records are saved with every write of the turn (as items of
\* the execution memory at their step's boundary), and a replay places a
\* step's failed attempts before its text and its record after it. Then a
\* replay shows exactly what the live view showed up to the last save.
\*
\* Planted bugs, one constant each:
\*   PinTop          records go to the top of the live view (fx before this)
\*   RecordsSaved    "never" (fx before this) or "commit": records are left
\*                   out of every write but the commit
\*   SplitFailures   FALSE: a replay puts failed attempts after the text
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Steps, MaxFails, PinTop, RecordsSaved, SplitFailures

ASSUME Steps \in Nat \ {0} /\ MaxFails \in Nat
ASSUME PinTop \in BOOLEAN /\ SplitFailures \in BOOLEAN
ASSUME RecordsSaved \in {"always", "commit", "never"}

Item(k, t, a) == [k |-> k, t |-> t, a |-> a]
Prompt == Item(0, "prompt", 0)
IsRecord(it) == it.t \in {"fail", "rec"}

VARIABLES
    events,     \* what happened, in time order
    live,       \* what the live Ctrl+O shows
    step,       \* the step running now
    fails,      \* failed attempts of that step so far
    stage,      \* "send", "text", "settle", "tools", "done"
    saved,      \* how many events the last write of the turn held
    committed,  \* the turn ended and was committed
    crashed,    \* fx stopped before the commit
    replay      \* what Ctrl+O shows after the resume

vars == <<events, live, step, fails, stage, saved, committed, crashed, replay>>

Init ==
    /\ events = <<Prompt>>
    /\ live = <<Prompt>>
    /\ step = 1
    /\ fails = 0
    /\ stage = "send"
    /\ saved = 0
    /\ committed = FALSE
    /\ crashed = FALSE
    /\ replay = <<>>

Running == ~committed /\ ~crashed
Happen(it) == events' = Append(events, it)

\* The model call fails; the step will send again.
Fail ==
    /\ Running /\ stage = "send" /\ fails < MaxFails
    /\ Happen(Item(step, "fail", fails + 1))
    /\ fails' = fails + 1
    /\ UNCHANGED <<live, step, stage, saved, committed, crashed, replay>>

\* The call answers: its text streams.
Text ==
    /\ Running /\ stage = "send"
    /\ Happen(Item(step, "text", 0))
    /\ stage' = "settle"
    /\ UNCHANGED <<live, step, fails, saved, committed, crashed, replay>>

\* The call settles: its record.
Settle ==
    /\ Running /\ stage = "settle"
    /\ Happen(Item(step, "rec", 0))
    /\ stage' = IF step < Steps THEN "tools" ELSE "done"
    /\ UNCHANGED <<live, step, fails, saved, committed, crashed, replay>>

\* The step's tools run; the next step begins.
Tools ==
    /\ Running /\ stage = "tools"
    /\ Happen(Item(step, "tool", 0))
    /\ step' = step + 1
    /\ fails' = 0
    /\ stage' = "send"
    /\ UNCHANGED <<live, saved, committed, crashed, replay>>

\* The app shows the next event. With PinTop, records go to the top.
Deliver ==
    /\ Len(live) < Len(events)
    /\ LET it == events[Len(live) + 1] IN
         live' = IF PinTop /\ IsRecord(it) THEN <<it>> \o live ELSE Append(live, it)
    /\ UNCHANGED <<events, step, fails, stage, saved, committed, crashed, replay>>

\* The structure a write saves from the first n events: per step, the failed
\* attempts and whether its text, record and tools are there.
Has(prefix, it) == \E i \in 1..Len(prefix) : prefix[i] = it
FailsIn(prefix, k) == Cardinality({i \in 1..Len(prefix) : prefix[i].k = k /\ prefix[i].t = "fail"})
Encode(prefix, records) ==
    [k \in 1..Steps |->
        [fails |-> IF records THEN FailsIn(prefix, k) ELSE 0,
         text |-> Has(prefix, Item(k, "text", 0)),
         rec |-> records /\ Has(prefix, Item(k, "rec", 0)),
         tool |-> Has(prefix, Item(k, "tool", 0))]]

\* A replay builds the view from the structure.
FailSeq(k, n) == [i \in 1..n |-> Item(k, "fail", i)]
One(cond, it) == IF cond THEN <<it>> ELSE <<>>
StepSeq(s, k) ==
    LET text == One(s[k].text, Item(k, "text", 0))
        rec == One(s[k].rec, Item(k, "rec", 0))
        tool == One(s[k].tool, Item(k, "tool", 0))
    IN IF SplitFailures
       THEN FailSeq(k, s[k].fails) \o text \o rec \o tool
       ELSE text \o FailSeq(k, s[k].fails) \o rec \o tool
RECURSIVE PlaceFrom(_, _)
PlaceFrom(s, k) == IF k > Steps THEN <<>> ELSE StepSeq(s, k) \o PlaceFrom(s, k + 1)
Place(s) == <<Prompt>> \o PlaceFrom(s, 1)

\* A write of the turn so far: the turn's pieces stream as they finish.
Save ==
    /\ Running /\ saved < Len(events)
    /\ saved' = Len(events)
    /\ UNCHANGED <<events, live, step, fails, stage, committed, crashed, replay>>

RecordsIn(isCommit) ==
    CASE RecordsSaved = "always" -> TRUE
      [] RecordsSaved = "commit" -> isCommit
      [] OTHER -> FALSE

Commit ==
    /\ Running /\ stage = "done"
    /\ committed' = TRUE
    /\ saved' = Len(events)
    /\ replay' = Place(Encode(events, RecordsIn(TRUE)))
    /\ UNCHANGED <<events, live, step, fails, stage, crashed>>

\* fx stops before the commit; the resume shows what the last write held,
\* and nothing of a turn no write reached.
Crash ==
    /\ Running
    /\ crashed' = TRUE
    /\ replay' = IF saved = 0 THEN <<>>
                 ELSE Place(Encode(SubSeq(events, 1, saved), RecordsIn(FALSE)))
    /\ UNCHANGED <<events, live, step, fails, stage, saved, committed>>

Next == Fail \/ Text \/ Settle \/ Tools \/ Deliver \/ Save \/ Commit \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ live \in Seq([k : 0..Steps, t : {"prompt", "fail", "text", "rec", "tool"}, a : 0..MaxFails])
    /\ saved \in 0..Len(events)

\* The live view shows what happened, in the order it happened.
LivePrefixOfEvents == live = SubSeq(events, 1, Len(live))

\* Nothing is shown above the prompt.
PromptFirst == live[1] = Prompt

\* After a resume, Ctrl+O shows what the live view showed up to the last
\* write: the same records, in the same places.
ReplayMatchesSaved ==
    (committed \/ crashed) => replay = SubSeq(events, 1, saved)
====
