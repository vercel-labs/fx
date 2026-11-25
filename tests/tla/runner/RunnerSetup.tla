---------------------------- MODULE RunnerSetup ----------------------------
(***************************************************************************)
(* Where a shell run goes, and the in-chat setup of a remote runner.       *)
(*                                                                         *)
(* This models code that has not landed: src/core/runner/ (decide, setup)  *)
(* and the built-in runner's login check. Its driver runs only with        *)
(* --next.                                                                 *)
(*                                                                         *)
(* Each call has fixed inputs: the model's `runner` request, the first     *)
(* matching rule, and the folder default. fx decides a target: an isolated *)
(* folder wins, then a rule, then the request, then the folder default,    *)
(* then local. A local target runs at once. A remote or isolated target    *)
(* needs a ready destination: a valid login and config.remote. When it is  *)
(* not ready and the call has a prompt channel, one setup runs at a time.  *)
(* Its REST calls list the teams (discover). With two or more teams fx     *)
(* opens the team prompt P1; a team accept is not consent, and the         *)
(* projects are listed next. With one team there is no P1. Then fx opens   *)
(* the project prompt P2: its accept is the consent. An accept starts a    *)
(* create or lookup step (create), then the locked write of config.remote  *)
(* (writing). A decline, a dismissed form or no answer on P1 or P2 sets    *)
(* the decline mark. A cancel stops a setup at once, except that a write   *)
(* which has started completes; the call then ends canceled and does not   *)
(* run. Other calls that need setup wait for the setup in flight, then     *)
(* check again. After a decline, no new prompt opens in the same user      *)
(* turn. The runner reads the login again at launch, so a login that       *)
(* changed after the check refuses the run.                                *)
(*                                                                         *)
(* Bug names one planted defect, or "none" for the design. check.sh lists  *)
(* each defect and the rule that must catch it.                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Calls,        \* the shell calls of one turn
    SubCalls,     \* the calls a sub-agent makes. fx never starts setup for
                  \* them (the TUI gives sub-agents a responder, but setup
                  \* refuses them), so the model gives them no prompt channel
    MaxAttempts,  \* how often the model may repeat one refused call
    MaxTurns,     \* user turns; a new turn may prompt again after a decline
    Requests,     \* the `runner` requests a call may carry. The one-call
                  \* config takes all three; the two-call configs take {"remote"}
                  \* to stay small (see check.sh and README)
    Bug

Rules    == {"none", "local", "remote", "isolated"}
Floors   == {"none", "remote", "isolated"}
Logins   == {"none", "expired", "valid", "other_user"}
Surfaces == {"interactive", "headless"}
\* "many" is two or more teams. A slug prompt for more than 60 teams is P1 too.
TeamCounts == {"one", "many"}
Targets  == {"local", "remote", "isolated"}
Statuses == {"new", "local", "check", "discover", "team", "setup", "waiting",
             "create", "writing", "launch", "ran", "refused"}
Terminal == {"ran", "refused"}
\* The statuses of the one setup in flight: its discovery, its team prompt,
\* its project prompt, its create or lookup step, and its write.
SetupPhases == {"discover", "team", "setup", "create", "writing"}
BadKinds == {"launch_unready", "prompt_after_decline", "prompt_after_cancel",
             "write_after_cancel", "write_without_project_accept"}

VARIABLES
    req,          \* call -> the model's `runner` field
    rule,         \* call -> the target of the first matching rule
    floor,        \* call -> the folder default
    surface,      \* "headless": fx ask without a terminal, or ACP without elicitation
    login,        \* the Vercel login as fx reads it
    loginChanged, \* the login changed once during the run of the model
    configured,   \* config.remote is present
    configValid,  \* ~/.fx/sandbox/config.json parses
    teams,        \* the teams of the login: "one", or "many" (two or more)
    st,           \* call -> status
    attempts,     \* call -> repeats used
    prompts,      \* the calls whose host prompt (P1 or P2) is open
    declined,     \* the decline mark: the user declined, dismissed or did not
                  \* answer a setup prompt in this turn, as fx recorded it
    turn,
    accepts,      \* project accepts so far (P2 is the consent)
    writes,       \* writes of config.remote so far
    ran,          \* call -> where its command last ran
    bad,          \* rule breaks seen by actions, for the invariants below
    canceled,     \* calls the user canceled before their write started, in
                  \* this attempt
    stopAfterWrite, \* calls the user canceled while their write ran: the write
                  \* completes, then the call ends canceled
    teamChosen,   \* calls whose team prompt was accepted in this attempt
    consented,    \* calls whose project prompt was accepted in this attempt
    userDeclined  \* the user declined, dismissed or did not answer a setup
                  \* prompt in this turn: what the user did, not what fx recorded

inputs == <<req, rule, floor, surface, configValid, teams>>
vars == <<req, rule, floor, surface, login, loginChanged, configured,
          configValid, teams, st, attempts, prompts, declined, turn, accepts,
          writes, ran, bad, canceled, stopAfterWrite, teamChosen, consented,
          userDeclined>>

DesignDecide(c) ==
    IF floor[c] = "isolated" THEN "isolated"
    ELSE IF rule[c] # "none" THEN rule[c]
    ELSE IF req[c] # "none" THEN req[c]
    ELSE IF floor[c] # "none" THEN floor[c]
    ELSE "local"

Decide(c) ==
    IF Bug = "request_beats_floor" /\ req[c] # "none" THEN req[c]
    ELSE IF Bug = "request_beats_rule" /\ floor[c] # "isolated" /\ req[c] # "none"
        THEN req[c]
    ELSE DesignDecide(c)

Channel(c) == surface = "interactive" /\ c \notin SubCalls

TrulyReady == configured /\ login = "valid"

\* Readiness as fx checks it before launch: a login, not expired, for the
\* user who confirmed config.remote.
CheckedReady ==
    \/ TrulyReady
    \/ Bug = "other_user_ok" /\ configured /\ login = "other_user"

Init ==
    /\ req \in [Calls -> Requests]
    /\ rule \in [Calls -> Rules]
    /\ floor \in [Calls -> Floors]
    /\ surface \in Surfaces
    /\ login \in Logins
    /\ loginChanged = FALSE
    /\ configured \in BOOLEAN
    /\ configValid \in BOOLEAN
    /\ teams \in TeamCounts
    /\ st = [c \in Calls |-> "new"]
    /\ attempts = [c \in Calls |-> 0]
    /\ prompts = {}
    /\ declined = FALSE
    /\ turn = 1
    /\ accepts = 0
    /\ writes = 0
    /\ ran = [c \in Calls |-> "nowhere"]
    /\ bad = {}
    /\ canceled = {}
    /\ stopAfterWrite = {}
    /\ teamChosen = {}
    /\ consented = {}
    /\ userDeclined = FALSE

SetSt(c, s) == st' = [st EXCEPT ![c] = s]

\* Another call holds the one setup in flight.
Busy == \E d \in Calls : st[d] \in SetupPhases

\* The prompt a setup opens next: P1 while the team is not chosen, P2 after.
\* With one team there is no P1.
NextPrompt(c) ==
    IF teams = "many" /\ c \notin teamChosen THEN "team" ELSE "setup"

\* The rule breaks a prompt opened now would cause: a prompt after a decline
\* in this turn, or a prompt for a call the user already canceled.
Violations(c) ==
    (IF userDeclined THEN {"prompt_after_decline"} ELSE {})
        \cup (IF c \in canceled THEN {"prompt_after_cancel"} ELSE {})

\* An invalid config refuses every run before deciding: a rule or floor in
\* the broken file could have applied.
Admit(c) ==
    /\ st[c] = "new"
    /\ IF ~configValid THEN SetSt(c, "refused")
       ELSE IF Decide(c) = "local" THEN SetSt(c, "local")
       ELSE SetSt(c, "check")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

RunLocal(c) ==
    /\ st[c] = "local"
    /\ SetSt(c, "ran")
    /\ ran' = [ran EXCEPT ![c] = "local"]
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* Login first, then readiness, then the prompt channel, then a decline in
\* this turn, then one setup at a time. A setup starts with its discovery.
Check(c) ==
    /\ st[c] = "check"
    /\ CASE login \in {"none", "expired"} ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
         [] CheckedReady ->
                /\ SetSt(c, "launch")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
         [] Bug = "write_without_confirm" /\ Channel(c) ->
                /\ configured' = TRUE
                /\ login' = "valid"
                /\ writes' = writes + 1
                /\ SetSt(c, "launch")
                /\ UNCHANGED <<prompts, accepts, bad>>
         [] ~Channel(c) /\ Bug # "headless_prompt" ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
         [] declined /\ Bug # "reprompt_after_decline" ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
         [] ~Busy ->
                /\ SetSt(c, "discover")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
         [] Bug = "double_prompt" ->
                /\ prompts' = prompts \cup {c}
                /\ SetSt(c, NextPrompt(c))
                /\ bad' = bad \cup Violations(c)
                /\ UNCHANGED <<configured, login, accepts, writes>>
         [] OTHER ->
                /\ SetSt(c, "waiting")
                /\ UNCHANGED <<prompts, configured, login, accepts, writes, bad>>
    /\ UNCHANGED <<inputs, loginChanged, attempts, declined, turn, ran, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* The REST steps before a prompt listed the teams, and the projects of the
\* chosen team. The host opens P1 or P2.
DiscoverDone(c) ==
    /\ st[c] = "discover"
    /\ prompts' = prompts \cup {c}
    /\ SetSt(c, NextPrompt(c))
    /\ bad' = bad \cup Violations(c)
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, declined,
                   turn, accepts, writes, ran, canceled, stopAfterWrite,
                   teamChosen, consented, userDeclined>>

\* A REST step before a prompt fails (E9, or E6 for a rejected login).
\* Nothing is written, and there is no decline mark.
DiscoverFail(c) ==
    /\ st[c] = "discover"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* P1, the team prompt. A team accept is not consent: it lists the projects,
\* and P2 opens next. The planted defect team_accept_consent counts it as
\* consent and goes straight to the write path.
TeamAccept(c) ==
    /\ c \in prompts
    /\ st[c] = "team"
    /\ prompts' = prompts \ {c}
    /\ teamChosen' = teamChosen \cup {c}
    /\ IF Bug = "team_accept_consent"
       THEN /\ accepts' = accepts + 1
            /\ SetSt(c, "create")
       ELSE /\ accepts' = accepts
            /\ SetSt(c, "discover")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, declined,
                   turn, writes, ran, bad, canceled, stopAfterWrite, consented,
                   userDeclined>>

\* P2, the project prompt. Its accept is the consent. The create or lookup
\* step follows, then the write.
ProjectAccept(c) ==
    /\ c \in prompts
    /\ st[c] = "setup"
    /\ prompts' = prompts \ {c}
    /\ accepts' = accepts + 1
    /\ consented' = consented \cup {c}
    /\ SetSt(c, "create")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, declined,
                   turn, writes, ran, bad, canceled, stopAfterWrite, teamChosen,
                   userDeclined>>

\* A decline, a dismissed form, or no answer on P1 or P2: nothing written, the
\* decline mark, and no new prompt in this turn. The planted defect
\* team_decline_no_mark sets no mark for P1; the user still declined, so
\* userDeclined records it.
FormDecline(c) ==
    /\ c \in prompts
    /\ prompts' = prompts \ {c}
    /\ IF Bug = "team_decline_no_mark" /\ st[c] = "team"
       THEN UNCHANGED declined
       ELSE declined' = TRUE
    /\ userDeclined' = TRUE
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, turn,
                   accepts, writes, ran, bad, canceled, stopAfterWrite,
                   teamChosen, consented>>

\* A REST call that fails while the answer is handled (E9): nothing written,
\* no decline mark.
AnswerRestFails(c) ==
    /\ c \in prompts
    /\ prompts' = prompts \ {c}
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, declined,
                   turn, accepts, writes, ran, bad, canceled, stopAfterWrite,
                   teamChosen, consented, userDeclined>>

Answer(c) == TeamAccept(c) \/ ProjectAccept(c) \/ FormDecline(c)
             \/ AnswerRestFails(c)

\* The create or lookup of the project succeeded. The write comes next.
CreateDone(c) ==
    /\ st[c] = "create"
    /\ SetSt(c, "writing")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* The create or lookup failed (E9). Nothing is written.
CreateFail(c) ==
    /\ st[c] = "create"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* The locked write is one atomic step. It sets config.remote for the login
\* that confirmed it, so an other-user login becomes the confirmed one. Setup
\* never creates a login: one that went missing or expired stays so. A cancel
\* that arrived meanwhile only sets stopAfterWrite, so the call ends canceled
\* after the write, and does not run.
WriteDone(c) ==
    /\ st[c] = "writing"
    /\ configured' = TRUE
    /\ login' = IF login = "other_user" THEN "valid" ELSE login
    /\ writes' = writes + 1
    /\ bad' = bad \cup (IF c \in canceled THEN {"write_after_cancel"} ELSE {})
                  \cup (IF c \in consented THEN {} ELSE {"write_without_project_accept"})
    /\ SetSt(c, IF c \in stopAfterWrite THEN "refused" ELSE "launch")
    /\ UNCHANGED <<inputs, loginChanged, attempts, prompts, declined, turn,
                   accepts, ran, canceled, stopAfterWrite, teamChosen,
                   consented, userDeclined>>

\* The write fails before it changes config.remote: E4, E14, or a write error.
WriteFail(c) ==
    /\ st[c] = "writing"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* A waiting call checks again once no setup is in flight.
Wake(c) ==
    /\ st[c] = "waiting"
    /\ ~Busy
    /\ Bug = "lost_wakeup" => ~declined
    /\ SetSt(c, IF Bug = "stale_wake" THEN "launch" ELSE "check")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, teamChosen, consented, userDeclined>>

\* The runner reads the login again and refuses when it changed. A started
\* runner may also fail to start the sandbox: the command did not run, and
\* it never runs locally instead.
Launch(c) ==
    /\ st[c] = "launch"
    /\ LET pinned == TrulyReady \/ Bug \in {"no_pin", "other_user_ok", "stale_wake"}
       IN IF ~pinned
          THEN /\ SetSt(c, "refused")
               /\ UNCHANGED <<ran, bad>>
          ELSE /\ bad' = IF TrulyReady THEN bad ELSE bad \cup {"launch_unready"}
               /\ \/ /\ SetSt(c, "ran")
                     /\ ran' = [ran EXCEPT ![c] = Decide(c)]
                  \/ /\ SetSt(c, "refused")
                     /\ ran' = IF Bug = "fallback_local"
                               THEN [ran EXCEPT ![c] = "local"]
                               ELSE ran
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   declined, turn, accepts, writes, canceled, stopAfterWrite,
                   teamChosen, consented, userDeclined>>

\* The planted defects that ignore a cancel in one phase: it is recorded, but
\* the call goes on.
CancelIgnored(c) ==
    \/ (Bug = "cancel_discover_ignored" /\ st[c] = "discover")
    \/ (Bug = "cancel_after_accept_writes" /\ st[c] = "create")

\* The user cancels the turn or the tool call (not the form) while the call is
\* in discovery, waiting, at P1 or P2, or in the create step. The call ends
\* canceled, with nothing written and no decline mark. A cancel during the
\* write is CancelDuringWrite.
Cancel(c) ==
    /\ st[c] \in {"discover", "team", "setup", "waiting", "create"}
    /\ canceled' = canceled \cup {c}
    /\ prompts' = prompts \ {c}
    /\ IF CancelIgnored(c) THEN UNCHANGED st ELSE SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, declined,
                   turn, accepts, writes, ran, bad, stopAfterWrite, teamChosen,
                   consented, userDeclined>>

\* A cancel that arrives while the write runs. The write is not interrupted.
CancelDuringWrite(c) ==
    /\ st[c] = "writing"
    /\ stopAfterWrite' = stopAfterWrite \cup {c}
    /\ UNCHANGED <<inputs, login, loginChanged, configured, st, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   teamChosen, consented, userDeclined>>

\* The user logs in again, or out, once, at any time.
ChangeLogin ==
    /\ ~loginChanged
    /\ login' \in Logins \ {login}
    /\ loginChanged' = TRUE
    /\ UNCHANGED <<inputs, configured, st, attempts, prompts, declined, turn,
                   accepts, writes, ran, bad, canceled, stopAfterWrite,
                   teamChosen, consented, userDeclined>>

\* The model repeats a refused call. It is a new attempt, so the setup history
\* of the old attempt does not carry over.
Retry(c) ==
    /\ st[c] = "refused"
    /\ attempts[c] < MaxAttempts
    /\ SetSt(c, "new")
    /\ attempts' = [attempts EXCEPT ![c] = @ + 1]
    /\ canceled' = canceled \ {c}
    /\ stopAfterWrite' = stopAfterWrite \ {c}
    /\ teamChosen' = teamChosen \ {c}
    /\ consented' = consented \ {c}
    /\ UNCHANGED <<inputs, login, loginChanged, configured, prompts, declined,
                   turn, accepts, writes, ran, bad, userDeclined>>

\* The next user turn may prompt again.
NewTurn ==
    /\ turn < MaxTurns
    /\ \A c \in Calls : st[c] \in Terminal
    /\ turn' = turn + 1
    /\ declined' = FALSE
    /\ userDeclined' = FALSE
    /\ st' = [c \in Calls |-> "new"]
    /\ ran' = [c \in Calls |-> "nowhere"]
    /\ canceled' = {}
    /\ stopAfterWrite' = {}
    /\ teamChosen' = {}
    /\ consented' = {}
    /\ UNCHANGED <<inputs, login, loginChanged, configured, attempts, prompts,
                   accepts, writes, bad>>

\* The steps fx takes on its own. The REST steps of a setup are among them.
System(c) == Admit(c) \/ RunLocal(c) \/ Check(c) \/ Wake(c) \/ Launch(c)
             \/ DiscoverDone(c) \/ DiscoverFail(c)
             \/ CreateDone(c) \/ CreateFail(c)
             \/ WriteDone(c) \/ WriteFail(c)

\* Every call has ended; nothing more happens. Keeps TLC from reporting the
\* end as a deadlock.
Done ==
    /\ \A c \in Calls : st[c] \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ \E c \in Calls : System(c) \/ Answer(c) \/ Cancel(c)
                       \/ CancelDuringWrite(c) \/ Retry(c)
    \/ ChangeLogin
    \/ NewTurn
    \/ Done

\* fx's own steps are fair, and the user answers an open prompt in the end.
\* Cancels, retries, login changes and new turns may never happen.
Fairness ==
    /\ \A c \in Calls : WF_vars(System(c))
    /\ \A c \in Calls : WF_vars(Answer(c))

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------
TypeOK ==
    /\ req \in [Calls -> Requests]
    /\ rule \in [Calls -> Rules]
    /\ floor \in [Calls -> Floors]
    /\ surface \in Surfaces
    /\ login \in Logins
    /\ loginChanged \in BOOLEAN
    /\ configured \in BOOLEAN
    /\ configValid \in BOOLEAN
    /\ teams \in TeamCounts
    /\ st \in [Calls -> Statuses]
    /\ attempts \in [Calls -> 0..MaxAttempts]
    /\ prompts \subseteq Calls
    /\ declined \in BOOLEAN
    /\ turn \in 1..MaxTurns
    /\ accepts \in Nat
    /\ writes \in Nat
    /\ ran \in [Calls -> Targets \cup {"nowhere"}]
    /\ bad \subseteq BadKinds
    /\ canceled \subseteq Calls
    /\ stopAfterWrite \subseteq Calls
    /\ teamChosen \subseteq Calls
    /\ consented \subseteq Calls
    /\ userDeclined \in BOOLEAN

\* Nothing in an isolated folder runs anywhere but isolated.
IsolatedFloor ==
    \A c \in Calls : floor[c] = "isolated" => ran[c] \in {"nowhere", "isolated"}

\* Outside an isolated folder, a matching rule sets the target.
RuleWins ==
    \A c \in Calls :
        floor[c] # "isolated" /\ rule[c] # "none" => ran[c] \in {"nowhere", rule[c]}

\* A command whose target is not local never runs on this machine.
NoLocalFallback ==
    \A c \in Calls : ran[c] = "local" => DesignDecide(c) = "local"

\* config.remote is written only after a user accept.
ConfigOnlyByUser == writes <= accepts

\* One host prompt at a time: P1 and P2 never overlap.
SinglePrompt == Cardinality(prompts) <= 1

\* A call without a prompt channel never waits on a prompt.
NoWaitWithoutChannel ==
    \A c \in Calls : ~Channel(c) => st[c] \notin {"team", "setup", "waiting"}

\* No new prompt in a turn after the user declined.
NoPromptAfterDecline == "prompt_after_decline" \notin bad

\* A remote or isolated run uses a set-up destination and the login that
\* confirmed it.
RemoteNeedsReady == "launch_unready" \notin bad

\* A call the user cancels before its write starts never writes.
NoWriteAfterEarlyCancel == "write_after_cancel" \notin bad

\* A call the user cancels never opens a prompt after the cancel.
NoPromptAfterCancel == "prompt_after_cancel" \notin bad

\* Only a P2 accept is consent: a write follows a project accept of the same
\* call, not a team accept at P1.
WriteOnlyAfterProjectAccept == "write_without_project_accept" \notin bad

\* Every call ends: it runs or is refused.
EventuallyEnds == <>[](\A c \in Calls : st[c] \in Terminal)
=============================================================================
