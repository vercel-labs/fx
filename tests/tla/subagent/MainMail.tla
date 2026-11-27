------------------------------- MODULE MainMail -------------------------------
(***************************************************************************)
(* How a subagent's report or message reaches main, and what `wait` says   *)
(* about it.                                                               *)
(*                                                                         *)
(* Mail joins main's running turn when the worker knows that turn          *)
(* (`WorkerRuntime.beginDirectProcessing`, which `fx ask` calls around     *)
(* each turn in `runAskTurn`, src/core/cli/cli_ask.zig; the app's worker   *)
(* loop marks its own turns), the turn has not closed at its final         *)
(* boundary, and no older mail waits (`postMailWith` in                    *)
(* src/core/agent/worker_runtime.zig). The turn takes its joined mail at   *)
(* each boundary (`takeSteeringBoundaryIntoInner`); a final boundary that  *)
(* finds none closes the turn. When the turn finishes, mail left for it    *)
(* waits for the next turn (`finishProcessing`), and the host starts one   *)
(* turn for the oldest waiting mail (the loop after `runAskTurn`;          *)
(* `runReportTurns` in src/acp/prompt.zig). ACP never marks its turns, so  *)
(* its mail always waits: Joins = FALSE.                                   *)
(*                                                                         *)
(* `wait` (`Runtime.waitForMail` in src/core/subagent/tool_host.zig) wakes *)
(* on any waiting mail. It says the mail follows only when some of it      *)
(* joined the running turn, and otherwise that it starts the next turn.    *)
(* It can also return at once, before it looks at mail: while the user's   *)
(* latest message in the turn has no visible answer, it asks the model to  *)
(* answer first, until the model takes a step after that return            *)
(* (`userAnswerOwed`). That return takes no mail and says neither, so this *)
(* model leaves it out; the inline tests in tool_host.zig pin it.          *)
(*                                                                         *)
(* Rules:                                                                  *)
(*   JoinsOpenTurn  where turns take mail, mail posted while main's turn   *)
(*                  is open, with nothing older waiting, reaches main in   *)
(*                  that turn, unless the turn ends early (Abort)          *)
(*   EachOnce       main reads each piece of mail once                     *)
(*   NoneLost       once no turn runs and nothing waits, main has read     *)
(*                  every piece of mail posted                             *)
(*   InOrder        main reads mail in the order it was posted             *)
(*   WaitHonest     wait says it follows only when main reads some of     *)
(*                  that mail in the same turn, and that it starts the     *)
(*                  next turn only when main reads none of it there        *)
(*                                                                         *)
(* Where the host commits a finished turn in a step of its own (the app:   *)
(* the worker pushes the turn's finish, and the main loop commits it to    *)
(* the session a pass later; `Commits`), mail that missed the turn must    *)
(* not start the next one first. A turn that starts first writes its first *)
(* piece into the log while the finished turn is still open, which         *)
(* supersedes both. The worker counts the finishes it pushed and the loop  *)
(* has not acknowledged (`owed`; `commit_gate`,                            *)
(* `acknowledgeFinishCommitted` and `acknowledgeFinishDropped` in          *)
(* worker_runtime.zig; the loop acknowledges a finish it drops unsaved, as *)
(* a cancel or a session switch does, as it does one it commits), holds    *)
(* that mail                                                               *)
(* while the count is above zero, and gives up after a limit               *)
(* (`commit_gate_limit_ms`). A stop of the worker also ends the hold; the  *)
(* model has no stop, as it has no close of the agent.                     *)
(*   CommitBeforeNextTurn  a turn never starts while an acknowledgement is *)
(*                  owed, unless the gate gave up on it                    *)
(*   GateNeverStuck the gate never waits for an acknowledgement that is    *)
(*                  not coming: it owes no more than commits remain        *)
(*                                                                         *)
(* Where the host hands a subagent's mail to its main loop before the      *)
(* worker's queue (the app: `postDelivery` appends to the hand-off list on *)
(* the subagent's thread, and the main loop's `deliverReports` posts it a  *)
(* pass later and only then takes it off the list; `Handoff`), the worker  *)
(* cannot see mail in that gap. A reply that ends with no text and the     *)
(* finish reason `other` (`EmptyReply`) is followed by the worker's check  *)
(* for mail, which takes what joined or closes the turn and sends a nudge  *)
(* (`Decide`). The check first asks the host whether mail waits in the     *)
(* hand-off (`wait_for_handoff_mail`), and if so waits on the worker's     *)
(* condition for it, at most MaxWait ticks (`Tick`, `GiveUp`); a stop or   *)
(* cancel ends the wait at once (`Abort`). So does older work that waits   *)
(* ahead of any new mail (`olderMailWaitsLocked`): none can join the turn, *)
(* so the wait is read from the worker's state and needs no signal that is *)
(* still to come, even when the mail is posted just before the wait. A     *)
(* turn that a check closed takes no more mail, so a second empty reply    *)
(* waits for nothing.                                                      *)
(*   NoNudgeWithMail  a nudge never goes out while mail waits in the       *)
(*                  hand-off, unless the wait gave up on it or older work  *)
(*                  keeps that mail out of the turn                        *)
(*   WaitBounded    the worker never waits longer than MaxWait ticks       *)
(*   NoPointlessWait  the worker never waits while older work keeps mail   *)
(*                  out of the turn                                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Mail,      \* the reports and messages subagents post to main
  MaxTurns,  \* how many turns main may run
  Joins,     \* TRUE where turns take mail (the app, fx ask); FALSE in ACP
  Commits,   \* TRUE where the host commits a finished turn in a later step (the app)
  Handoff,   \* TRUE where mail waits in the host's hand-off before the worker's queue (the app)
  Bug        \* "none" is the design; the others are fx before it or planted

Bugs == {"none",
         "today",               \* fx ask before: no turn is marked, wait always says it follows
         "wait_always_follows", \* wait says it follows whatever the mail does
         "lost_at_finish",      \* a finished turn drops the mail left for it
         "close_with_mail",     \* a final boundary closes the turn with joined mail unread
         "no_gate",            \* the next turn starts without waiting for the commit
         "stuck_gate",         \* a commit leaves the gate's count as it was
         "drop_unacknowledged",\* a finish the loop drops unsaved leaves the gate's count as it was
         "nudge_blind",        \* an empty reply's check ignores mail in the hand-off (fx before the wait)
         "unbounded_wait",     \* the worker waits for mail in the hand-off with no bound
         "wait_behind"}        \* the worker keeps waiting for mail that older work keeps out of the turn

ASSUME /\ Bug \in Bugs
       /\ Joins \in BOOLEAN
       /\ Commits \in BOOLEAN
       /\ Handoff \in BOOLEAN
       /\ MaxTurns \in Nat \ {0}

VARIABLES
  turn,     \* main's running turn, 0 between turns
  turns,    \* how many turns have started
  open,     \* the running turn still takes mail: no final boundary closed it
  marked,   \* the worker knows the running turn
  queue,    \* waiting mail: a sequence of [m |-> mail, t |-> the turn it joined, or 0]
  posted,   \* the mail posted so far, in order
  readIn,   \* mail -> the turn main read it in, 0 while unread
  order,    \* the mail main read, in the order it read it
  due,      \* mail -> the turn it must reach main in, or 0 (JoinsOpenTurn)
  aborted,  \* turns that ended early
  waits,    \* wait's answers: [t |-> turn, mail |-> what waited, said |-> "follows" | "next"]
  twice,    \* main read some mail a second time
  uncommitted, \* finished turns the main loop has not committed yet
  owed,     \* finishes the worker counts as not acknowledged: what holds the next turn
  early,    \* a turn started while the worker still counted an unacknowledged finish
  hand      \* the hand-off: [list |-> mail the host queued and the loop has not posted,
            \*   empty |-> an empty reply's step has ended and the worker decides,
            \*   waited |-> ticks the worker has waited for the list, gaveUp |-> the bound passed,
            \*   pointless |-> the worker waited while older work kept mail out of the turn,
            \*   nudges |-> the nudges sent: [t |-> turn, listed |-> mail then in the list, gaveUp |-> ...,
            \*   behind |-> older work kept that mail out of the turn]]

vars == <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early, hand>>
commitVars == <<uncommitted, owed, early>>

Range(s) == {s[i] : i \in DOMAIN s}
Mails(s) == [i \in DOMAIN s |-> s[i].m]
Joined == SelectSeq(queue, LAMBDA e : e.t = turn)
Rest == SelectSeq(queue, LAMBDA e : e.t # turn)
\* Nothing older than the running turn's own mail waits (olderMailWaitsLocked).
NothingOlder == \A i \in DOMAIN queue : queue[i].t = turn
Marks == Joins /\ Bug # "today"
\* The bound on the worker's wait for mail in the hand-off, in ticks
\* (`handoff_mail_wait_ms` in src/core/agent/runtime/orchestrator.zig).
MaxWait == 2
Index(s, x) == CHOOSE i \in DOMAIN s : s[i] = x

\* Main reads the mail `ms`, in order, in turn `t`.
Read(ms, t) ==
  /\ readIn' = [m \in Mail |-> IF m \in Range(ms) THEN t ELSE readIn[m]]
  /\ twice' = (twice \/ \E i \in DOMAIN ms : readIn[ms[i]] # 0)
  /\ order' = order \o ms

Init ==
  /\ turn = 0
  /\ turns = 0
  /\ open = FALSE
  /\ marked = FALSE
  /\ queue = <<>>
  /\ posted = <<>>
  /\ readIn = [m \in Mail |-> 0]
  /\ order = <<>>
  /\ due = [m \in Mail |-> 0]
  /\ aborted = {}
  /\ waits = {}
  /\ twice = FALSE
  /\ uncommitted = 0
  /\ owed = 0
  /\ early = FALSE
  /\ hand = [list |-> <<>>, empty |-> FALSE, waited |-> 0, gaveUp |-> FALSE, pointless |-> FALSE, nudges |-> {}]

\* The user's prompt starts main's first turn.
UserTurn ==
  /\ turns = 0
  /\ turn' = 1
  /\ turns' = 1
  /\ open' = TRUE
  /\ marked' = Marks
  /\ UNCHANGED <<queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early, hand>>

\* Mail `m` reaches main's queue (`postMailWith`), joining the running turn
\* when it can.
Arrive(m) ==
  /\ LET joins == turn # 0 /\ marked /\ open /\ NothingOlder
     IN queue' = Append(queue, [m |-> m, t |-> IF joins THEN turn ELSE 0])
  /\ due' = [due EXCEPT ![m] = IF Joins /\ turn # 0 /\ open /\ NothingOlder THEN turn ELSE 0]
  /\ posted' = Append(posted, m)

\* A subagent posts mail to main. Subagents exist once main's first turn
\* has started one.
Post(m) ==
  /\ ~Handoff
  /\ turns > 0
  /\ m \notin Range(posted)
  /\ Arrive(m)
  /\ UNCHANGED <<turn, turns, open, marked, readIn, order, aborted, waits, twice, uncommitted, owed, early, hand>>

\* A boundary of the running turn takes the mail that joined it.
Take ==
  /\ turn # 0
  /\ open
  /\ ~hand.empty
  /\ Joined # <<>>
  /\ queue' = Rest
  /\ Read(Mails(Joined), turn)
  /\ UNCHANGED <<turn, turns, open, marked, posted, due, aborted, waits, uncommitted, owed, early, hand>>

\* A final boundary that finds no joined mail closes the turn.
Close ==
  /\ turn # 0
  /\ open
  /\ ~hand.empty
  /\ Joined = <<>> \/ Bug = "close_with_mail"
  /\ open' = FALSE
  /\ UNCHANGED <<turn, turns, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early, hand>>

\* The turn ends early, as a failed or cancelled request ends it. A stop,
\* a shutdown, or a cancel also ends a wait for mail at once.
Abort ==
  /\ turn # 0
  /\ open
  /\ open' = FALSE
  /\ aborted' = aborted \cup {turn}
  /\ hand' = [hand EXCEPT !.empty = FALSE, !.waited = 0, !.gaveUp = FALSE]
  /\ UNCHANGED <<turn, turns, marked, queue, posted, readIn, order, due, waits, twice, uncommitted, owed, early>>

\* The turn finishes; the mail left for it waits for the next turn.
Finish ==
  /\ turn # 0
  /\ ~open
  /\ queue' = IF Bug = "lost_at_finish" THEN Rest
              ELSE [i \in DOMAIN queue |->
                      IF queue[i].t = turn THEN [m |-> queue[i].m, t |-> 0] ELSE queue[i]]
  /\ turn' = 0
  /\ marked' = FALSE
  /\ uncommitted' = uncommitted + (IF Commits THEN 1 ELSE 0)
  /\ owed' = owed + (IF Commits THEN 1 ELSE 0)
  /\ UNCHANGED <<turns, open, posted, readIn, order, due, aborted, waits, twice, early, hand>>

\* Between turns, the oldest waiting mail starts main's next turn.
NextTurn ==
  /\ turn = 0
  /\ turns > 0
  /\ turns < MaxTurns
  /\ queue # <<>>
  /\ (owed = 0 \/ Bug = "no_gate")
  /\ early' = (early \/ owed > 0)
  /\ turn' = turns + 1
  /\ turns' = turns + 1
  /\ open' = TRUE
  /\ marked' = Marks
  /\ queue' = Tail(queue)
  /\ Read(<<Head(queue).m>>, turns + 1)
  /\ UNCHANGED <<posted, due, aborted, waits, uncommitted, owed, hand>>

\* `wait` wakes on waiting mail and says whether it follows. Its return
\* that asks the model to answer the user first takes no mail, so it is
\* not an action here (see the header).
Wait ==
  /\ turn # 0
  /\ open
  /\ ~hand.empty
  /\ queue # <<>>
  /\ LET said == IF Bug \in {"today", "wait_always_follows"} \/ Joined # <<>>
                 THEN "follows" ELSE "next"
     IN waits' = waits \cup {[t |-> turn, mail |-> Range(Mails(queue)), said |-> said]}
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, twice, uncommitted, owed, early, hand>>

\* The main loop commits a finished turn to the session and acknowledges it
\* (`appendFinishedPrompt`), whether the commit worked or failed. An
\* acknowledgement for a finish the gate gave up on counts for nothing.
Commit ==
  /\ uncommitted > 0
  /\ uncommitted' = uncommitted - 1
  /\ owed' = IF Bug = "stuck_gate" \/ owed = 0 THEN owed ELSE owed - 1
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, early, hand>>

\* The main loop drops a finished turn without committing it, as a cancel or a
\* session switch drops the one the pacer held, or a drain that cannot save
\* drops what is left (`acknowledgeFinishDropped`). Nothing will commit it, so
\* the drop is acknowledged as a commit is.
Drop ==
  /\ uncommitted > 0
  /\ uncommitted' = uncommitted - 1
  /\ owed' = IF Bug = "drop_unacknowledged" \/ owed = 0 THEN owed ELSE owed - 1
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, early, hand>>

\* The limit passes with the commit still owed: the gate forgets it and lets
\* the mail start the next turn, as before the gate (`commit_gate_expired`).
Expire ==
  /\ owed > 0
  /\ owed' = 0
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, early, hand>>

\* The host queues a subagent's mail in its hand-off (`postDelivery`), on the
\* subagent's thread. Only the main loop posts it to the worker.
Queue(m) ==
  /\ Handoff
  /\ turns > 0
  /\ m \notin Range(posted) \cup Range(hand.list)
  /\ hand' = [hand EXCEPT !.list = Append(@, m)]
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* The main loop posts the oldest mail in the hand-off to the worker's queue
\* (`deliverReports`), and only then takes it off the list.
Deliver ==
  /\ Handoff
  /\ hand.list # <<>>
  /\ Arrive(Head(hand.list))
  /\ hand' = [hand EXCEPT !.list = Tail(@)]
  /\ UNCHANGED <<turn, turns, open, marked, readIn, order, aborted, waits, twice, uncommitted, owed, early>>

\* The turn's step ends with an empty reply, the finish reason `other` and no
\* text or tool call. The worker now decides between waiting for mail,
\* taking it, and the nudge.
EmptyReply ==
  /\ Handoff
  /\ turn # 0
  /\ open
  /\ ~hand.empty
  /\ hand' = [hand EXCEPT !.empty = TRUE]
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* The worker waits on its condition for the mail in the hand-off, and a tick
\* of the bound passes. A wait ends when mail joins the turn, which signals
\* that condition, and when older work keeps mail out of the turn, which the
\* worker reads from its state.
Tick ==
  /\ hand.empty
  /\ open
  /\ hand.list # <<>>
  /\ Joined = <<>>
  /\ (NothingOlder \/ Bug = "wait_behind")
  /\ ~hand.gaveUp
  /\ (hand.waited < MaxWait \/ Bug = "unbounded_wait")
  /\ hand' = [hand EXCEPT !.waited = @ + 1, !.pointless = @ \/ ~NothingOlder]
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* The bound passes with the mail still in the hand-off: the wait ends, and
\* the worker logs that the mail did not land in time.
GiveUp ==
  /\ Bug # "unbounded_wait"
  /\ hand.empty
  /\ open
  /\ hand.list # <<>>
  /\ Joined = <<>>
  /\ (NothingOlder \/ Bug = "wait_behind")
  /\ ~hand.gaveUp
  /\ hand.waited = MaxWait
  /\ hand' = [hand EXCEPT !.gaveUp = TRUE]
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* The worker's check as the empty reply's step ends, once it waits for
\* nothing more (`takeSteeringBoundaryIntoInner`, finalizing): it takes the
\* mail that joined, which replaces the nudge, or closes the turn and sends
\* the nudge. It waits for nothing more when the list is empty, mail joined,
\* the bound passed, or older work keeps new mail out of the turn.
Decide ==
  /\ hand.empty
  /\ turn # 0
  /\ open
  /\ \/ hand.list = <<>>
     \/ Joined # <<>>
     \/ hand.gaveUp
     \/ (~NothingOlder /\ Bug # "wait_behind")
     \/ Bug = "nudge_blind"
  /\ \/ /\ Joined # <<>>
        /\ queue' = Rest
        /\ Read(Mails(Joined), turn)
        /\ hand' = [hand EXCEPT !.empty = FALSE, !.waited = 0, !.gaveUp = FALSE]
        /\ UNCHANGED open
     \/ /\ Joined = <<>>
        /\ open' = FALSE
        /\ hand' = [hand EXCEPT !.empty = FALSE, !.waited = 0, !.gaveUp = FALSE,
                     !.nudges = @ \cup {[t |-> turn, listed |-> Range(hand.list), gaveUp |-> hand.gaveUp, behind |-> ~NothingOlder]}]
        /\ UNCHANGED <<queue, readIn, order, twice>>
  /\ UNCHANGED <<turn, turns, marked, posted, due, aborted, waits, uncommitted, owed, early>>

Next ==
  \/ UserTurn
  \/ \E m \in Mail : Post(m)
  \/ \E m \in Mail : Queue(m)
  \/ Deliver
  \/ EmptyReply
  \/ Tick
  \/ GiveUp
  \/ Decide
  \/ Take
  \/ Close
  \/ Abort
  \/ Finish
  \/ NextTurn
  \/ Wait
  \/ Commit
  \/ Drop
  \/ Expire

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ turn \in 0..MaxTurns
  /\ turns \in 0..MaxTurns
  /\ open \in BOOLEAN
  /\ marked \in BOOLEAN
  /\ \A i \in DOMAIN queue : queue[i].m \in Mail /\ queue[i].t \in 0..MaxTurns
  /\ Range(posted) \subseteq Mail
  /\ readIn \in [Mail -> 0..MaxTurns]
  /\ due \in [Mail -> 0..MaxTurns]
  /\ twice \in BOOLEAN
  /\ uncommitted \in 0..MaxTurns
  /\ owed \in 0..MaxTurns
  /\ early \in BOOLEAN
  /\ Range(hand.list) \subseteq Mail
  /\ hand.empty \in BOOLEAN
  /\ hand.waited \in 0..(MaxWait + 1)
  /\ hand.gaveUp \in BOOLEAN
  /\ hand.pointless \in BOOLEAN
  /\ \A n \in hand.nudges : n.t \in 0..MaxTurns /\ n.listed \subseteq Mail /\ n.gaveUp \in BOOLEAN /\ n.behind \in BOOLEAN

JoinsOpenTurn ==
  \A m \in Mail :
    (due[m] # 0 /\ due[m] \notin aborted /\ (readIn[m] # 0 \/ turn # due[m]))
      => readIn[m] = due[m]

EachOnce == ~twice

NoneLost ==
  (turn = 0 /\ queue = <<>>) => \A i \in DOMAIN posted : readIn[posted[i]] # 0

InOrder ==
  \A i, j \in DOMAIN order :
    i < j => Index(posted, order[i]) < Index(posted, order[j])

WaitHonest ==
  \A w \in waits :
    w.t \notin aborted =>
      /\ (w.said = "follows" /\ turn # w.t) => \E m \in w.mail : readIn[m] = w.t
      /\ w.said = "next" => \A m \in w.mail : readIn[m] # w.t

CommitBeforeNextTurn == ~early

GateNeverStuck == owed <= uncommitted

NoNudgeWithMail == \A n \in hand.nudges : n.listed = {} \/ n.gaveUp \/ n.behind

WaitBounded == hand.waited <= MaxWait

NoPointlessWait == ~hand.pointless

=============================================================================
