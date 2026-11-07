------------------------- MODULE CommandEnvironment -------------------------
(***************************************************************************)
(* What an automatic command review tells the reviewer about the shell     *)
(* that will run the command (src/core/tooling/tool_admission.zig          *)
(* reviewRequestForCall and src/core/permissions/auto_classifier.zig       *)
(* serializeEvidence).                                                     *)
(*                                                                         *)
(* One shell call at a time is admitted. A routine command runs without    *)
(* review, as it does today; this model does not change which commands     *)
(* reach review. Every other command gets a review request, whose command  *)
(* action is serialized into the review packet. A packet with incomplete   *)
(* action evidence is held as unavailable without a reviewer call. A       *)
(* complete packet goes to the reviewer, which may answer clear or         *)
(* caution; only clear runs the command, in the environment of the call.   *)
(*                                                                         *)
(* The environments are those of command_environment.Environment:          *)
(*   user             the user's login shell, which reads the user's       *)
(*                    startup files, so their aliases and functions apply  *)
(*   clean            the same shell with startup files skipped            *)
(*   workspace_clean  the browser workspace shell                          *)
(*   legacy           the plain `sh -lc` path, which names no shell        *)
(* A user or clean call names its shell, zsh or bash, or "none" when the   *)
(* path is empty or cannot be told. The other two carry "na".              *)
(*                                                                         *)
(* Bug selects fx before the change or one planted defect:                 *)
(*   "none"              the design                                        *)
(*   "today"             the packet has no environment, shell, or startup  *)
(*                       line and always says the evidence is complete     *)
(*   "unwired"           the request drops the call's environment, so the  *)
(*                       packet names legacy                               *)
(*   "no_startup"        the packet names the environment and shell but    *)
(*                       not whether startup definitions apply             *)
(*   "unnamed_complete"  a shell-routed call with no shell name is still   *)
(*                       sent as complete evidence                         *)
(*   "review_set"        the change also sends routine user-profile        *)
(*                       commands to review, which is I258's decision      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Commands,   \* subset of {"routine", "reviewed"}
    Shells,     \* subset of {"zsh", "bash", "none"}
    MaxCalls,   \* bound on calls in one behavior
    Bug

Envs == {"user", "clean", "workspace_clean", "legacy"}
ShellRouted(e) == e \in {"user", "clean"}
StartupOf(e) == CASE e = "user" -> "applies"
                  [] e = "clean" -> "skipped"
                  [] OTHER -> "absent"

Calls ==
    [cmd : Commands, env : {"user", "clean"}, shell : Shells]
    \cup [cmd : Commands, env : {"workspace_clean", "legacy"}, shell : {"na"}]

NoPacket == [env |-> "absent", shell |-> "absent", startup |-> "absent", complete |-> FALSE]
NoCall == [cmd |-> "none", env |-> "none", shell |-> "none"]

VARIABLES
    phase,          \* "idle", "admitted", "requested", "serialized", "decided", "done"
    call,           \* the pending call
    requestEnv,     \* the environment the review request carries
    requestShell,   \* the shell the review request carries
    packet,         \* what the reviewer is shown about the interpreter
    reviewed,       \* the call went to review
    reviewerCalls,  \* reviewer requests sent for this call
    decision,       \* "none", "clear", "caution", "unavailable", "unreviewed"
    ran,            \* the command ran
    startupRan,     \* the user's startup files ran before it
    calls           \* calls admitted so far

vars == <<phase, call, requestEnv, requestShell, packet, reviewed, reviewerCalls, decision, ran, startupRan, calls>>

Reset ==
    /\ phase' = "idle"
    /\ call' = NoCall
    /\ requestEnv' = "absent"
    /\ requestShell' = "absent"
    /\ packet' = NoPacket
    /\ reviewed' = FALSE
    /\ reviewerCalls' = 0
    /\ decision' = "none"
    /\ ran' = FALSE
    /\ startupRan' = FALSE

Init ==
    /\ phase = "idle"
    /\ call = NoCall
    /\ requestEnv = "absent"
    /\ requestShell = "absent"
    /\ packet = NoPacket
    /\ reviewed = FALSE
    /\ reviewerCalls = 0
    /\ decision = "none"
    /\ ran = FALSE
    /\ startupRan = FALSE
    /\ calls = 0

\* The agent proposes one shell call.
Propose(c) ==
    /\ phase = "idle"
    /\ calls < MaxCalls
    /\ phase' = "admitted"
    /\ call' = c
    /\ calls' = calls + 1
    /\ UNCHANGED <<requestEnv, requestShell, packet, reviewed, reviewerCalls, decision, ran, startupRan>>

\* Shared admission: a routine command runs without review. With the
\* review_set defect, a routine user-profile command is reviewed as well.
GoesToReview(c) ==
    \/ c.cmd = "reviewed"
    \/ Bug = "review_set" /\ c.env = "user"

RunUnreviewed ==
    /\ phase = "admitted"
    /\ ~GoesToReview(call)
    /\ phase' = "done"
    /\ decision' = "unreviewed"
    /\ ran' = TRUE
    /\ startupRan' = (call.env = "user")
    /\ UNCHANGED <<call, requestEnv, requestShell, packet, reviewed, reviewerCalls, calls>>

\* reviewRequestForCall copies the run's command context into the command
\* action. Before the change, and with the unwired defect, the environment
\* is not copied.
BuildRequest ==
    /\ phase = "admitted"
    /\ GoesToReview(call)
    /\ phase' = "requested"
    /\ reviewed' = TRUE
    /\ requestEnv' = CASE Bug = "today" -> "absent"
                       [] Bug = "unwired" -> "legacy"
                       [] OTHER -> call.env
    /\ requestShell' = CASE Bug \in {"today", "unwired"} -> "na"
                         [] OTHER -> call.shell
    /\ UNCHANGED <<call, packet, reviewerCalls, decision, ran, startupRan, calls>>

\* serializeEvidence writes the command action section.
Serialize ==
    /\ phase = "requested"
    /\ phase' = "serialized"
    /\ packet' =
        IF Bug = "today"
        THEN [env |-> "absent", shell |-> "absent", startup |-> "absent", complete |-> TRUE]
        ELSE [env |-> requestEnv,
              shell |-> IF ShellRouted(requestEnv) THEN requestShell ELSE "absent",
              startup |-> IF Bug = "no_startup" THEN "absent" ELSE StartupOf(requestEnv),
              complete |-> ~(ShellRouted(requestEnv) /\ requestShell = "none" /\ Bug # "unnamed_complete")]
    /\ UNCHANGED <<call, requestEnv, requestShell, reviewed, reviewerCalls, decision, ran, startupRan, calls>>

\* Incomplete action evidence is held before any reviewer call
\* (auto_classifier.zig Reviewer.review returns evidence_incomplete).
HoldIncomplete ==
    /\ phase = "serialized"
    /\ ~packet.complete
    /\ phase' = "decided"
    /\ decision' = "unavailable"
    /\ UNCHANGED <<call, requestEnv, requestShell, packet, reviewed, reviewerCalls, ran, startupRan, calls>>

\* The reviewer is outside fx's control: it may answer either way.
Review(d) ==
    /\ phase = "serialized"
    /\ packet.complete
    /\ phase' = "decided"
    /\ reviewerCalls' = reviewerCalls + 1
    /\ decision' = d
    /\ UNCHANGED <<call, requestEnv, requestShell, packet, reviewed, ran, startupRan, calls>>

\* Only a clear runs the command, in the call's own environment: a user
\* shell reads the user's startup files first, a clean one does not.
Execute ==
    /\ phase = "decided"
    /\ decision = "clear"
    /\ phase' = "done"
    /\ ran' = TRUE
    /\ startupRan' = (call.env = "user")
    /\ UNCHANGED <<call, requestEnv, requestShell, packet, reviewed, reviewerCalls, decision, calls>>

Hold ==
    /\ phase = "decided"
    /\ decision \in {"caution", "unavailable"}
    /\ phase' = "done"
    /\ UNCHANGED <<call, requestEnv, requestShell, packet, reviewed, reviewerCalls, decision, ran, startupRan, calls>>

\* The agent loop moves on to its next call.
Continue ==
    /\ phase = "done"
    /\ Reset
    /\ UNCHANGED calls

Next ==
    \/ \E c \in Calls : Propose(c)
    \/ RunUnreviewed
    \/ BuildRequest
    \/ Serialize
    \/ HoldIncomplete
    \/ \E d \in {"clear", "caution"} : Review(d)
    \/ Execute
    \/ Hold
    \/ Continue

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ phase \in {"idle", "admitted", "requested", "serialized", "decided", "done"}
    /\ call \in Calls \cup {NoCall}
    /\ requestEnv \in Envs \cup {"absent"}
    /\ requestShell \in Shells \cup {"na", "absent"}
    /\ packet.env \in Envs \cup {"absent"}
    /\ packet.shell \in Shells \cup {"na", "absent"}
    /\ packet.startup \in {"applies", "skipped", "absent"}
    /\ packet.complete \in BOOLEAN
    /\ reviewed \in BOOLEAN
    /\ reviewerCalls \in 0..1
    /\ decision \in {"none", "clear", "caution", "unavailable", "unreviewed"}
    /\ ran \in BOOLEAN
    /\ startupRan \in BOOLEAN
    /\ calls \in 0..MaxCalls

\* A reviewed command runs only after a clear given on a packet that named
\* the environment and, for a shell route, the shell it runs under.
ReviewerSeesInterpreter ==
    (ran /\ reviewed) =>
        /\ packet.env = call.env
        /\ ShellRouted(call.env) => packet.shell = call.shell

\* ... and said truthfully whether the user's startup aliases and functions
\* applied: "applies" exactly when the startup files ran before it.
StartupDisclosed ==
    (ran /\ reviewed) =>
        /\ packet.startup = StartupOf(call.env)
        /\ (packet.startup = "applies") <=> startupRan

\* A shell-routed command whose shell cannot be named is held as
\* unavailable without a reviewer call, and never runs after review.
UnnamedShellNeverRuns ==
    (phase = "done" /\ reviewed /\ ShellRouted(call.env) /\ call.shell = "none") =>
        /\ decision = "unavailable"
        /\ reviewerCalls = 0
        /\ ~ran

\* Complete evidence always names the interpreter.
CompleteOnlyWhenNamed ==
    (phase \in {"serialized", "decided", "done"} /\ reviewed /\ packet.complete) =>
        /\ packet.env # "absent"
        /\ ShellRouted(packet.env) => packet.shell \in {"zsh", "bash"}

\* The change does not alter which commands reach review (I258 is separate).
ReviewSetUnchanged ==
    (phase = "done") => (reviewed <=> call.cmd = "reviewed")

\* A review sends at most one reviewer request.
OneReviewPerCall == reviewerCalls <= 1
=============================================================================
