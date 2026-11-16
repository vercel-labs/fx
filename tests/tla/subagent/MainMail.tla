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
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Mail,      \* the reports and messages subagents post to main
  MaxTurns,  \* how many turns main may run
  Joins,     \* TRUE where turns take mail (the app, fx ask); FALSE in ACP
  Commits,   \* TRUE where the host commits a finished turn in a later step (the app)
  Bug        \* "none" is the design; the others are fx before it or planted

Bugs == {"none",
         "today",               \* fx ask before: no turn is marked, wait always says it follows
         "wait_always_follows", \* wait says it follows whatever the mail does
         "lost_at_finish",      \* a finished turn drops the mail left for it
         "close_with_mail",     \* a final boundary closes the turn with joined mail unread
         "no_gate",            \* the next turn starts without waiting for the commit
         "stuck_gate",         \* a commit leaves the gate's count as it was
         "drop_unacknowledged"}\* a finish the loop drops unsaved leaves the gate's count as it was

ASSUME /\ Bug \in Bugs
       /\ Joins \in BOOLEAN
       /\ Commits \in BOOLEAN
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
  early     \* a turn started while the worker still counted an unacknowledged finish

vars == <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>
commitVars == <<uncommitted, owed, early>>

Range(s) == {s[i] : i \in DOMAIN s}
Mails(s) == [i \in DOMAIN s |-> s[i].m]
Joined == SelectSeq(queue, LAMBDA e : e.t = turn)
Rest == SelectSeq(queue, LAMBDA e : e.t # turn)
\* Nothing older than the running turn's own mail waits (olderMailWaitsLocked).
NothingOlder == \A i \in DOMAIN queue : queue[i].t = turn
Marks == Joins /\ Bug # "today"
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

\* The user's prompt starts main's first turn.
UserTurn ==
  /\ turns = 0
  /\ turn' = 1
  /\ turns' = 1
  /\ open' = TRUE
  /\ marked' = Marks
  /\ UNCHANGED <<queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* A subagent posts mail to main. Subagents exist once main's first turn
\* has started one.
Post(m) ==
  /\ turns > 0
  /\ m \notin Range(posted)
  /\ LET joins == turn # 0 /\ marked /\ open /\ NothingOlder
     IN queue' = Append(queue, [m |-> m, t |-> IF joins THEN turn ELSE 0])
  /\ due' = [due EXCEPT ![m] = IF Joins /\ turn # 0 /\ open /\ NothingOlder THEN turn ELSE 0]
  /\ posted' = Append(posted, m)
  /\ UNCHANGED <<turn, turns, open, marked, readIn, order, aborted, waits, twice, uncommitted, owed, early>>

\* A boundary of the running turn takes the mail that joined it.
Take ==
  /\ turn # 0
  /\ open
  /\ Joined # <<>>
  /\ queue' = Rest
  /\ Read(Mails(Joined), turn)
  /\ UNCHANGED <<turn, turns, open, marked, posted, due, aborted, waits, uncommitted, owed, early>>

\* A final boundary that finds no joined mail closes the turn.
Close ==
  /\ turn # 0
  /\ open
  /\ Joined = <<>> \/ Bug = "close_with_mail"
  /\ open' = FALSE
  /\ UNCHANGED <<turn, turns, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, owed, early>>

\* The turn ends early, as a failed or cancelled request ends it.
Abort ==
  /\ turn # 0
  /\ open
  /\ open' = FALSE
  /\ aborted' = aborted \cup {turn}
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
  /\ UNCHANGED <<turns, open, posted, readIn, order, due, aborted, waits, twice, early>>

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
  /\ UNCHANGED <<posted, due, aborted, waits, uncommitted, owed>>

\* `wait` wakes on waiting mail and says whether it follows.
Wait ==
  /\ turn # 0
  /\ open
  /\ queue # <<>>
  /\ LET said == IF Bug \in {"today", "wait_always_follows"} \/ Joined # <<>>
                 THEN "follows" ELSE "next"
     IN waits' = waits \cup {[t |-> turn, mail |-> Range(Mails(queue)), said |-> said]}
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, twice, uncommitted, owed, early>>

\* The main loop commits a finished turn to the session and acknowledges it
\* (`appendFinishedPrompt`), whether the commit worked or failed. An
\* acknowledgement for a finish the gate gave up on counts for nothing.
Commit ==
  /\ uncommitted > 0
  /\ uncommitted' = uncommitted - 1
  /\ owed' = IF Bug = "stuck_gate" \/ owed = 0 THEN owed ELSE owed - 1
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, early>>

\* The main loop drops a finished turn without committing it, as a cancel or a
\* session switch drops the one the pacer held, or a drain that cannot save
\* drops what is left (`acknowledgeFinishDropped`). Nothing will commit it, so
\* the drop is acknowledged as a commit is.
Drop ==
  /\ uncommitted > 0
  /\ uncommitted' = uncommitted - 1
  /\ owed' = IF Bug = "drop_unacknowledged" \/ owed = 0 THEN owed ELSE owed - 1
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, early>>

\* The limit passes with the commit still owed: the gate forgets it and lets
\* the mail start the next turn, as before the gate (`commit_gate_expired`).
Expire ==
  /\ owed > 0
  /\ owed' = 0
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice, uncommitted, early>>

Next ==
  \/ UserTurn
  \/ \E m \in Mail : Post(m)
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

=============================================================================
