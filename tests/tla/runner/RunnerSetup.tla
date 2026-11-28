---------------------------- MODULE RunnerSetup ----------------------------
(***************************************************************************)
(* Where a shell run goes, and the copy question that sets up a remote     *)
(* runner for one repository.                                              *)
(*                                                                         *)
(* This models the code in src/core/runner/ (decide, setup) and the        *)
(* built-in runner's login check. Its driver runs only with --next.        *)
(*                                                                         *)
(* Each call has fixed inputs: its repository, the model's `runner`        *)
(* request, and the first matching rule and folder default. fx decides a   *)
(* target: an isolated folder wins, then a rule, then the request, then    *)
(* the folder default, then local. A local target runs at once. A remote   *)
(* or isolated target needs three things, checked in this order:           *)
(*   1. Login. None or expired refuses. The login is read again at launch, *)
(*      so a login that changed after the check refuses the run.           *)
(*   2. Destination, with no question (read-only REST). The team comes     *)
(*      from the setting, the CLI, or the account default, and the project *)
(*      from the setting or fx-sandbox. No team, a team that is not found, *)
(*      a set project that is missing, or a failed REST call refuses.      *)
(*      Nothing is written in any of these.                                *)
(*   3. The consent record of the repository, for this destination. A      *)
(*      record for another destination does not count.                     *)
(* When 1 and 2 hold and the record is missing, fx asks the copy question, *)
(* once per repository and destination. A yes makes fx-sandbox if it is   *)
(* missing, writes the remote slot and the consent record, then runs. A    *)
(* no, a dismissal, or no answer (timeout) sets the decline mark and       *)
(* writes nothing. A failed create or write refuses. A cancel stops a      *)
(* call at once, except that a write which has started completes; the call *)
(* then ends canceled and does not run.                                    *)
(*                                                                         *)
(* Channel rules. A sub-agent call never asks (E10). A call with no prompt *)
(* channel never waits on a prompt. One question is open at a time (U3),   *)
(* and the other calls wait for it. The decline mark (U4) is per turn.     *)
(* after a no, dismissal or no answer, no new question opens in the same   *)
(* turn, and a call with no consent record is refused. A new turn clears   *)
(* the mark, so it may ask again. A call whose consent is already on       *)
(* record still runs.                                                      *)
(*                                                                         *)
(* Bug names one planted defect, or "none" for the design. check.sh lists  *)
(* each defect and the rule that must catch it.                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Calls,             \* the shell calls of one turn
    SubCalls,          \* the calls a sub-agent makes: no prompt channel (E10)
    Repos,             \* the repositories the calls run in
    Requests,          \* the `runner` requests a call may carry
    RuleChoices,       \* the rules a call may match; "none" means no rule
    FloorChoices,      \* the folder defaults a call may have
    SurfaceChoices,    \* "interactive", "headless", or both
    LoginChoices,      \* the logins a run may start from
    ConfiguredChoices, \* TRUE, FALSE, or both: the remote slot is set
    ValidChoices,      \* TRUE, FALSE, or both: ~/.fx/sandbox/config.json parses
    DestChoices,       \* TRUE, FALSE, or both: the destination resolves
    SandboxChoices,    \* TRUE, FALSE, or both: fx-sandbox exists at the start
    RecordChoices,     \* the consent record each repository starts with
    MaxAttempts,       \* how often the model may repeat one refused call
    MaxTurns,          \* user turns
    Bug

\* Each config narrows the input sets. The one-call config takes the full
\* sets, so the decide rules are checked over every input. The two-call
\* configs fix the request, rule, and floor to a remote call, and check the
\* repository, consent, login, and prompt rules over every other input.

Rules    == {"none", "local", "remote", "isolated"}
Floors   == {"none", "remote", "isolated"}
Logins   == {"none", "expired", "valid", "other_user"}
Surfaces == {"interactive", "headless"}
Targets  == {"local", "remote", "isolated"}
\* The consent record of a repository: "none", "dest" (for this destination),
\* or "other" (for another destination).
Records  == {"none", "dest", "other"}
Statuses == {"new", "local", "check", "discover", "ask", "waiting",
             "create", "writing", "launch", "ran", "refused"}
Terminal == {"ran", "refused"}
\* The one setup in flight: its discovery, its copy question, its create or
\* lookup step, and its write.
SetupPhases == {"discover", "ask", "create", "writing"}
BadKinds == {"launch_unready", "launch_without_consent", "create_before_yes",
             "consent_without_yes", "prompt_after_decline",
             "prompt_after_cancel", "prompt_without_channel",
             "write_after_cancel"}

VARIABLES
    req,            \* call -> the model's `runner` field
    rule,           \* call -> the target of the first matching rule
    floor,          \* call -> the folder default
    repo,           \* call -> its repository
    surface,        \* "headless": fx ask without a terminal, or ACP without elicitation
    login,          \* the Vercel login as fx reads it
    loginChanged,   \* the login changed once during the run of the model
    configured,     \* the remote slot, config.remote, is present
    configValid,    \* ~/.fx/sandbox/config.json parses
    destOk,         \* the destination resolves: a team and a project
    sandboxExists,  \* fx-sandbox exists
    rec,            \* repository -> its consent record
    st,             \* call -> status
    attempts,       \* call -> repeats used
    prompts,        \* the calls whose copy question is open
    declined,       \* the decline mark: the user declined, dismissed or did not
                    \* answer a copy question, as fx recorded it
    turn,
    accepts,        \* yes answers so far
    writes,         \* writes of the remote slot so far
    ran,            \* call -> where its command last ran
    bad,            \* rule breaks seen by actions, for the invariants below
    canceled,       \* calls the user canceled before their write started, in
                    \* this attempt
    stopAfterWrite, \* calls the user canceled while their write ran: the write
                    \* completes, then the call ends canceled
    consented,      \* calls that answered yes in this attempt
    userDeclined,   \* the user declined, dismissed or did not answer a copy
                    \* question: what the user did, not what fx recorded
    priorDeclined   \* the decline mark was set in an earlier turn: history for
                    \* the witness, never read by the design

inputs == <<req, rule, floor, repo, surface, configValid, destOk>>
vars == <<req, rule, floor, repo, surface, login, loginChanged, configured,
          configValid, destOk, sandboxExists, rec, st, attempts, prompts,
          declined, turn, accepts, writes, ran, bad, canceled,
          stopAfterWrite, consented, userDeclined, priorDeclined>>

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

\* The headless and sub-agent defects let a call without a channel prompt.
Relaxed(c) ==
    \/ Bug = "headless_prompt" /\ surface = "headless"
    \/ Bug = "sub_agent_prompt" /\ c \in SubCalls

HasConsent(c) == rec[repo[c]] = "dest"

TrulyReady == configured /\ login = "valid"

\* Login readiness as fx checks it before launch. The other-user defect counts
\* a login for another user as ready.
LoginReady ==
    \/ TrulyReady
    \/ Bug = "other_user_ok" /\ configured /\ login = "other_user"

CheckedReady(c) ==
    LoginReady /\ (HasConsent(c) \/ Bug = "launch_without_consent")

SetSt(c, s) == st' = [st EXCEPT ![c] = s]

\* Another call holds the one setup in flight.
Busy == \E d \in Calls : st[d] \in SetupPhases

\* The rule breaks a copy question opened now would cause: a question after a
\* decline in this turn, or for a call the user already canceled.
Violations(c) ==
    (IF userDeclined THEN {"prompt_after_decline"} ELSE {})
        \cup (IF c \in canceled THEN {"prompt_after_cancel"} ELSE {})

\* A question for a call with no prompt channel.
PromptChannelBad(c) == IF Channel(c) THEN {} ELSE {"prompt_without_channel"}

\* A step that makes fx-sandbox is bad when the call that makes it has no yes.
CreateBad(c) == IF c \in consented THEN {} ELSE {"create_before_yes"}

\* A step that writes a consent record is bad when the call that writes it has
\* no yes.
ConsentBad(c) == IF c \in consented THEN {} ELSE {"consent_without_yes"}

\* Launch breaks: the login was not ready, or the repository has no consent.
LaunchBad(c) ==
    (IF TrulyReady THEN {} ELSE {"launch_unready"})
        \cup (IF HasConsent(c) THEN {} ELSE {"launch_without_consent"})

CancelIgnored(c) ==
    \/ (Bug = "cancel_discover_ignored" /\ st[c] = "discover")
    \/ (Bug = "cancel_after_accept_writes" /\ st[c] = "create")

Init ==
    /\ req \in [Calls -> Requests]
    /\ rule \in [Calls -> RuleChoices]
    /\ floor \in [Calls -> FloorChoices]
    /\ repo \in [Calls -> Repos]
    /\ surface \in SurfaceChoices
    /\ login \in LoginChoices
    /\ loginChanged = FALSE
    /\ configured \in ConfiguredChoices
    /\ configValid \in ValidChoices
    /\ destOk \in DestChoices
    /\ sandboxExists \in SandboxChoices
    /\ rec \in [Repos -> RecordChoices]
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
    /\ consented = {}
    /\ userDeclined = FALSE
    /\ priorDeclined = FALSE

\* An invalid config refuses every run before deciding: a rule or floor in
\* the broken file could have applied.
Admit(c) ==
    /\ st[c] = "new"
    /\ IF ~configValid THEN SetSt(c, "refused")
       ELSE IF Decide(c) = "local" THEN SetSt(c, "local")
       ELSE SetSt(c, "check")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, ran, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

RunLocal(c) ==
    /\ st[c] = "local"
    /\ SetSt(c, "ran")
    /\ ran' = [ran EXCEPT ![c] = "local"]
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

\* Login first, then readiness, then the prompt channel, then the decline mark,
\* then one setup at a time. A setup starts with its discovery.
Check(c) ==
    /\ st[c] = "check"
    /\ CASE login \in {"none", "expired"} ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
         [] CheckedReady(c) ->
                /\ SetSt(c, "launch")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
         [] ~Channel(c) /\ ~Relaxed(c) ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
         [] declined /\ Bug # "reprompt_after_decline" ->
                /\ SetSt(c, "refused")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
         [] ~Busy ->
                /\ SetSt(c, "discover")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
         [] Bug = "double_prompt" ->
                /\ prompts' = prompts \cup {c}
                /\ SetSt(c, "ask")
                /\ bad' = bad \cup Violations(c) \cup PromptChannelBad(c)
         [] OTHER ->
                /\ SetSt(c, "waiting")
                /\ UNCHANGED <<prompts, bad, priorDeclined>>
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, declined, turn, accepts, writes, ran, canceled,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The REST steps before a question listed the teams and projects. A destination
\* that does not resolve refuses before any question. Otherwise fx opens the
\* copy question.
DiscoverDone(c) ==
    /\ st[c] = "discover"
    /\ IF ~destOk
       THEN /\ SetSt(c, "refused")
            /\ UNCHANGED <<prompts, bad, sandboxExists, priorDeclined>>
       ELSE /\ prompts' = prompts \cup {c}
            /\ SetSt(c, "ask")
            \* The planted defect makes fx-sandbox here, before the question.
            \* The marker comes from the state change, not from the defect.
            /\ sandboxExists' = IF Bug = "create_before_yes" THEN TRUE
                                 ELSE sandboxExists
            /\ bad' = bad \cup Violations(c) \cup PromptChannelBad(c)
                          \cup (IF ~sandboxExists /\ sandboxExists'
                                 THEN CreateBad(c) ELSE {})
    /\ UNCHANGED <<inputs, login, loginChanged, configured, rec,
                   attempts, declined, turn, accepts, writes, ran, canceled,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* A REST step before the question fails. Nothing is written, and there is no
\* decline mark.
DiscoverFail(c) ==
    /\ st[c] = "discover"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, ran, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The user says yes. The yes is the consent. The create step follows if
\* fx-sandbox is missing, then the write.
ProjectAccept(c) ==
    /\ c \in prompts
    /\ st[c] = "ask"
    /\ prompts' = prompts \ {c}
    /\ accepts' = accepts + 1
    /\ consented' = consented \cup {c}
    /\ SetSt(c, IF sandboxExists THEN "writing" ELSE "create")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, declined, turn, writes, ran, bad, canceled,
                   stopAfterWrite, userDeclined, priorDeclined>>

\* The user says no, dismisses the question, or does not answer it in time.
\* Nothing is written. The decline mark is set. The planted defect
\* decline_no_mark leaves the mark unset. The planted defect consent_on_decline
\* writes the consent record anyway.
FormDecline(c) ==
    /\ c \in prompts
    /\ st[c] = "ask"
    /\ prompts' = prompts \ {c}
    /\ IF Bug = "decline_no_mark" THEN UNCHANGED declined ELSE declined' = TRUE
    /\ userDeclined' = TRUE
    /\ rec' = IF Bug = "consent_on_decline"
              THEN [rec EXCEPT ![repo[c]] = "dest"]
              ELSE rec
    /\ bad' = bad \cup (IF rec[repo[c]] # "dest" /\ rec'[repo[c]] = "dest"
                        THEN ConsentBad(c) ELSE {})
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists,
                   attempts, turn, accepts, writes, ran, canceled,
                   stopAfterWrite, consented, priorDeclined>>

Answer(c) == ProjectAccept(c) \/ FormDecline(c)

\* The create step makes fx-sandbox. It runs only after a yes.
CreateDone(c) ==
    /\ st[c] = "create"
    /\ sandboxExists' = TRUE
    /\ bad' = bad \cup (IF ~sandboxExists /\ sandboxExists' THEN CreateBad(c)
                        ELSE {})
    /\ SetSt(c, "writing")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, rec, attempts,
                   prompts, declined, turn, accepts, writes, ran, canceled,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The create fails (the project cannot be made). Nothing is written.
CreateFail(c) ==
    /\ st[c] = "create"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, ran, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The write is one atomic step. It sets the remote slot for the login that
\* confirmed it, and the consent record of the repository. Setup never creates
\* a login: one that went missing or expired stays so. A cancel that arrived
\* meanwhile only sets stopAfterWrite, so the call ends canceled after the
\* write, and does not run.
WriteDone(c) ==
    /\ st[c] = "writing"
    /\ configured' = TRUE
    /\ login' = IF login = "other_user" THEN "valid" ELSE login
    /\ rec' = [rec EXCEPT ![repo[c]] = "dest"]
    /\ writes' = writes + 1
    /\ bad' = bad \cup (IF c \in canceled THEN {"write_after_cancel"} ELSE {})
                  \cup ConsentBad(c)
    /\ SetSt(c, IF c \in stopAfterWrite THEN "refused" ELSE "launch")
    /\ UNCHANGED <<inputs, loginChanged, sandboxExists, attempts, prompts,
                   declined, turn, accepts, ran, canceled, stopAfterWrite,
                   consented, userDeclined, priorDeclined>>

\* The write fails before it changes the remote slot or the record.
WriteFail(c) ==
    /\ st[c] = "writing"
    /\ SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, ran, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

\* A waiting call checks again once no setup is in flight.
Wake(c) ==
    /\ st[c] = "waiting"
    /\ ~Busy
    /\ (Bug = "lost_wakeup") => ~declined
    /\ SetSt(c, IF Bug = "stale_wake" THEN "launch" ELSE "check")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, ran, bad,
                   canceled, stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The runner reads the login again and refuses when it changed. A started
\* runner may also fail to start the sandbox: the command did not run, and it
\* never runs locally instead.
Launch(c) ==
    /\ st[c] = "launch"
    /\ LET pinned == TrulyReady \/ Bug \in {"no_pin", "other_user_ok", "stale_wake"}
       IN IF ~pinned
          THEN /\ SetSt(c, "refused")
               /\ UNCHANGED <<ran, bad, priorDeclined>>
          ELSE /\ bad' = bad \cup LaunchBad(c)
               /\ \/ /\ SetSt(c, "ran")
                     /\ ran' = [ran EXCEPT ![c] = Decide(c)]
                  \/ /\ SetSt(c, "refused")
                     /\ ran' = IF Bug = "fallback_local"
                               THEN [ran EXCEPT ![c] = "local"]
                               ELSE ran
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, declined, turn, accepts, writes, canceled,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The user cancels the turn or the tool call (not the question) while the call
\* waits in discovery, waits for a setup, has its question open, or is in the
\* create step. The call ends canceled, with nothing written and no decline
\* mark. A cancel during the write is CancelDuringWrite.
Cancel(c) ==
    /\ st[c] \in {"discover", "waiting", "ask", "create"}
    /\ canceled' = canceled \cup {c}
    /\ prompts' = prompts \ {c}
    /\ IF CancelIgnored(c) THEN UNCHANGED st ELSE SetSt(c, "refused")
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, declined, turn, accepts, writes, ran, bad,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* A cancel that arrives while the write runs. The write is not interrupted.
CancelDuringWrite(c) ==
    /\ st[c] = "writing"
    /\ stopAfterWrite' = stopAfterWrite \cup {c}
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   st, attempts, prompts, declined, turn, accepts, writes, ran,
                   bad, canceled, consented, userDeclined, priorDeclined>>

\* The user logs in again, or out, once, at any time.
ChangeLogin ==
    /\ ~loginChanged
    /\ login' \in Logins \ {login}
    /\ loginChanged' = TRUE
    /\ UNCHANGED <<inputs, configured, sandboxExists, rec, st, attempts, prompts,
                   declined, turn, accepts, writes, ran, bad, canceled,
                   stopAfterWrite, consented, userDeclined, priorDeclined>>

\* The model repeats a refused call. It is a new attempt, so the setup history
\* of the old attempt does not carry over.
Retry(c) ==
    /\ st[c] = "refused"
    /\ attempts[c] < MaxAttempts
    /\ SetSt(c, "new")
    /\ attempts' = [attempts EXCEPT ![c] = @ + 1]
    /\ canceled' = canceled \ {c}
    /\ stopAfterWrite' = stopAfterWrite \ {c}
    /\ consented' = consented \ {c}
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   prompts, declined, turn, accepts, writes, ran, bad,
                   userDeclined, priorDeclined>>

\* The next user turn clears the decline mark, so a question may open again.
\* The consent records carry over.
NewTurn ==
    /\ turn < MaxTurns
    /\ \A c \in Calls : st[c] \in Terminal
    /\ turn' = turn + 1
    /\ st' = [c \in Calls |-> "new"]
    /\ ran' = [c \in Calls |-> "nowhere"]
    /\ canceled' = {}
    /\ stopAfterWrite' = {}
    /\ consented' = {}
    /\ declined' = FALSE
    /\ userDeclined' = FALSE
    /\ priorDeclined' = (priorDeclined \/ declined)
    /\ UNCHANGED <<inputs, login, loginChanged, configured, sandboxExists, rec,
                   attempts, prompts, accepts, writes, bad>>

\* The steps fx takes on its own.
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

\* fx's own steps are fair, and the user answers an open question in the end.
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
    /\ repo \in [Calls -> Repos]
    /\ surface \in Surfaces
    /\ login \in Logins
    /\ loginChanged \in BOOLEAN
    /\ configured \in BOOLEAN
    /\ configValid \in BOOLEAN
    /\ destOk \in BOOLEAN
    /\ sandboxExists \in BOOLEAN
    /\ rec \in [Repos -> Records]
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
    /\ consented \subseteq Calls
    /\ userDeclined \in BOOLEAN
    /\ priorDeclined \in BOOLEAN

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

\* A remote or isolated run needs the consent record of its repository for this
\* destination. Only a yes writes it.
NoCopyWithoutConsent == "launch_without_consent" \notin bad

\* fx-sandbox is made only after a yes.
NoVercelWriteBeforeYes == "create_before_yes" \notin bad

\* The consent record is written only for a call that got a yes.
ConsentOnlyByPerson == "consent_without_yes" \notin bad

\* A call without a prompt channel never opens a question.
NoPromptWithoutChannel == "prompt_without_channel" \notin bad

\* One question at a time.
SinglePrompt == Cardinality(prompts) <= 1

\* No new question in the same turn after the user declined.
NoPromptAfterDecline == "prompt_after_decline" \notin bad

\* A remote or isolated run uses a set-up destination and the login that
\* confirmed it.
RemoteNeedsReady == "launch_unready" \notin bad

\* A call the user cancels before its write starts never writes.
NoWriteAfterEarlyCancel == "write_after_cancel" \notin bad

\* A call the user cancels never opens a question after the cancel.
NoPromptAfterCancel == "prompt_after_cancel" \notin bad

\* Every call ends: it runs or is refused.
EventuallyEnds == <>[](\A c \in Calls : st[c] \in Terminal)

---------------------------------------------------------------------------
\* Witnesses. Each one claims that a state cannot happen, and its config must
\* see it violated, which shows the path is reachable.

\* A remote run happens at all.
NoRemoteRun == \A c \in Calls : ran[c] # "remote"

\* A remote run whose call did not get its own yes in this attempt: the consent
\* of another call, or of an earlier attempt or turn, carried it.
NoConsentReuse == \A c \in Calls : ran[c] = "remote" => c \in consented

\* A question opens in a later turn after a decline in an earlier turn.
NoQuestionAfterEarlierDecline == ~(priorDeclined /\ \E c \in Calls : st[c] = "ask")
=============================================================================
