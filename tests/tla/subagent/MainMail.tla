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
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Mail,      \* the reports and messages subagents post to main
  MaxTurns,  \* how many turns main may run
  Joins,     \* TRUE where turns take mail (the app, fx ask); FALSE in ACP
  Bug        \* "none" is the design; the others are fx before it or planted

Bugs == {"none",
         "today",               \* fx ask before: no turn is marked, wait always says it follows
         "wait_always_follows", \* wait says it follows whatever the mail does
         "lost_at_finish",      \* a finished turn drops the mail left for it
         "close_with_mail"}     \* a final boundary closes the turn with joined mail unread

ASSUME /\ Bug \in Bugs
       /\ Joins \in BOOLEAN
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
  twice     \* main read some mail a second time

vars == <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, waits, twice>>

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

\* The user's prompt starts main's first turn.
UserTurn ==
  /\ turns = 0
  /\ turn' = 1
  /\ turns' = 1
  /\ open' = TRUE
  /\ marked' = Marks
  /\ UNCHANGED <<queue, posted, readIn, order, due, aborted, waits, twice>>

\* A subagent posts mail to main. Subagents exist once main's first turn
\* has started one.
Post(m) ==
  /\ turns > 0
  /\ m \notin Range(posted)
  /\ LET joins == turn # 0 /\ marked /\ open /\ NothingOlder
     IN queue' = Append(queue, [m |-> m, t |-> IF joins THEN turn ELSE 0])
  /\ due' = [due EXCEPT ![m] = IF Joins /\ turn # 0 /\ open /\ NothingOlder THEN turn ELSE 0]
  /\ posted' = Append(posted, m)
  /\ UNCHANGED <<turn, turns, open, marked, readIn, order, aborted, waits, twice>>

\* A boundary of the running turn takes the mail that joined it.
Take ==
  /\ turn # 0
  /\ open
  /\ Joined # <<>>
  /\ queue' = Rest
  /\ Read(Mails(Joined), turn)
  /\ UNCHANGED <<turn, turns, open, marked, posted, due, aborted, waits>>

\* A final boundary that finds no joined mail closes the turn.
Close ==
  /\ turn # 0
  /\ open
  /\ Joined = <<>> \/ Bug = "close_with_mail"
  /\ open' = FALSE
  /\ UNCHANGED <<turn, turns, marked, queue, posted, readIn, order, due, aborted, waits, twice>>

\* The turn ends early, as a failed or cancelled request ends it.
Abort ==
  /\ turn # 0
  /\ open
  /\ open' = FALSE
  /\ aborted' = aborted \cup {turn}
  /\ UNCHANGED <<turn, turns, marked, queue, posted, readIn, order, due, waits, twice>>

\* The turn finishes; the mail left for it waits for the next turn.
Finish ==
  /\ turn # 0
  /\ ~open
  /\ queue' = IF Bug = "lost_at_finish" THEN Rest
              ELSE [i \in DOMAIN queue |->
                      IF queue[i].t = turn THEN [m |-> queue[i].m, t |-> 0] ELSE queue[i]]
  /\ turn' = 0
  /\ marked' = FALSE
  /\ UNCHANGED <<turns, open, posted, readIn, order, due, aborted, waits, twice>>

\* Between turns, the oldest waiting mail starts main's next turn.
NextTurn ==
  /\ turn = 0
  /\ turns > 0
  /\ turns < MaxTurns
  /\ queue # <<>>
  /\ turn' = turns + 1
  /\ turns' = turns + 1
  /\ open' = TRUE
  /\ marked' = Marks
  /\ queue' = Tail(queue)
  /\ Read(<<Head(queue).m>>, turns + 1)
  /\ UNCHANGED <<posted, due, aborted, waits>>

\* `wait` wakes on waiting mail and says whether it follows.
Wait ==
  /\ turn # 0
  /\ open
  /\ queue # <<>>
  /\ LET said == IF Bug \in {"today", "wait_always_follows"} \/ Joined # <<>>
                 THEN "follows" ELSE "next"
     IN waits' = waits \cup {[t |-> turn, mail |-> Range(Mails(queue)), said |-> said]}
  /\ UNCHANGED <<turn, turns, open, marked, queue, posted, readIn, order, due, aborted, twice>>

Next ==
  \/ UserTurn
  \/ \E m \in Mail : Post(m)
  \/ Take
  \/ Close
  \/ Abort
  \/ Finish
  \/ NextTurn
  \/ Wait

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

=============================================================================
