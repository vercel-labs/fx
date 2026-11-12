---- MODULE GitAdmission ----
\* fx's route for an agent git command, from planning through admission to
\* execution, over every permission mode, shell environment, command form and
\* repository state (src/core/shell_command/safe_git.zig).
\*
\* Contract (AGENTS.md): safe git runs the direct read-only status,
\* diff and log forms in an environment other than the user's own shell. In
\* auto mode a git command safe git refuses is returned to the agent unrun.
\* Shell-run git (the default user environment, auto mode's routine
\* commands) uses the repository's full config; that exposure is documented.
\*
\* Workspace capture is a second caller. It never goes through permission
\* admission: it writes into an fx-owned bare store whose config fx created,
\* with GIT_DIR, the capture index and the work tree set explicitly, so the
\* user's repository config and index are never read or written. When the
\* trusted git is missing the capture is unavailable; it never falls back to
\* plain git. CaptureIsolated = FALSE plants the bug where the store route
\* reads the repository (GIT_DIR unset), which every capture property catches.
EXTENDS Naturals, Sequences

CONSTANTS HoldEnabled, CaptureIsolated

Callers == {"agent", "capture"}
Modes == {"auto", "ask"}
Envs == {"clean", "user"}
Cmds == {"status", "status_other", "diff", "log"}
Repos == {"clean", "poisoned", "unreadable", "mismatch", "notrepo"}
\* Whether the trusted git exists and is new enough for the store route.
StoreGits == {"supported", "missing"}
\* Repository states whose own config names a program.
Poisoned == {"poisoned", "unreadable", "mismatch"}
\* Forms the planner sends to safe git (status --short, diff --stat,
\* log --oneline -n 3); status_other is `git status --ignored`.
Allowlisted == {"status", "diff", "log"}
\* Safe git refuses when it cannot read the config or git would pick
\* another repository.
Refuses == {"unreadable", "mismatch"}
\* Auto mode's routine-command rule runs any `git status` form unreviewed.
Reversible == {"status", "status_other"}
\* Forms that run a repository program under plain git: status refreshes the
\* index (fsmonitor, clean filter); diff also runs the external diff driver.
\* `git log --oneline` runs none.
FiresInPlain == {"status", "status_other", "diff"}
Verdicts == {"clear", "caution"}
CaptureRoutes == {"capture_store", "capture_unavailable"}

VARIABLES caller, mode, env, cmd, repo, storeGit, verdict, plan, route, fired, userIndexWritten, pc, history
vars == <<caller, mode, env, cmd, repo, storeGit, verdict, plan, route, fired, userIndexWritten, pc, history>>

Init ==
    /\ caller \in Callers
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos
    /\ storeGit \in StoreGits
    \* The security reviewer's verdict, used only on the review route.
    /\ verdict \in Verdicts
    /\ plan = "none" /\ route = "none" /\ fired = FALSE /\ userIndexWritten = FALSE
    /\ pc = "plan" /\ history = <<>>

\* A capture depends only on the trusted git, never on the repository's
\* config, the permission mode or the shell environment. For an agent
\* command, safe git is prepared before the arguments are checked, so a
\* refusal wins.
PlanResult ==
    IF caller = "capture" THEN
        IF storeGit = "supported" THEN "capture_store" ELSE "capture_unavailable"
    ELSE IF env = "user" \/ mode # "auto" THEN "dynamic_shell"
    ELSE IF repo \in Refuses THEN "unsafe_git"
    ELSE IF cmd \notin Allowlisted THEN "unsupported_argument"
    ELSE "direct"

AdmitResult ==
    IF plan \in CaptureRoutes THEN plan
    ELSE IF plan = "direct" THEN "direct"
    ELSE IF mode = "ask" THEN "prompt"
    ELSE IF plan = "unsafe_git" /\ HoldEnabled THEN "held"
    ELSE IF cmd \in Reversible THEN "approved_shell"
    ELSE "review"

Plan ==
    /\ pc = "plan" /\ plan' = PlanResult /\ pc' = "admit"
    /\ history' = Append(history, "Plan")
    /\ UNCHANGED <<caller, mode, env, cmd, repo, storeGit, verdict, route, fired, userIndexWritten>>

Admit ==
    /\ pc = "admit" /\ route' = AdmitResult /\ pc' = "execute"
    /\ history' = Append(history, "Admit")
    /\ UNCHANGED <<caller, mode, env, cmd, repo, storeGit, verdict, plan, fired, userIndexWritten>>

\* Plain git, reached unreviewed or through a review that clears, runs the
\* repository's programs; safe git, a held command, a prompt and a cautioned
\* review run none.
RunsPlainGit == route = "approved_shell" \/ (route = "review" /\ verdict = "clear")
\* The store route reads the repository only in the planted bug: then a
\* capture refreshes the user's index and runs its programs like plain git.
CaptureReadsRepository == route = "capture_store" /\ ~CaptureIsolated
Execute ==
    /\ pc = "execute"
    /\ fired' = \/ (RunsPlainGit /\ repo \in Poisoned /\ cmd \in FiresInPlain)
                \/ (CaptureReadsRepository /\ repo \in Poisoned)
    /\ userIndexWritten' = CaptureReadsRepository
    /\ pc' = "done" /\ history' = Append(history, "Execute")
    /\ UNCHANGED <<caller, mode, env, cmd, repo, storeGit, verdict, plan, route>>

Next == Plan \/ Admit \/ Execute
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ caller \in Callers
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos /\ verdict \in Verdicts
    /\ storeGit \in StoreGits
    /\ pc \in {"plan", "admit", "execute", "done"}
    /\ fired \in BOOLEAN /\ userIndexWritten \in BOOLEAN

\* G1: in auto mode, a command safe git refused never reaches plain git.
HoldSafety == (pc = "done" /\ mode = "auto" /\ plan = "unsafe_git") => route # "approved_shell"
\* Safe git never runs a repository program.
DirectNeverFires == route = "direct" => ~fired
\* Programs run only on the documented shell path.
ExposureOnlyDocumented == fired => (route \in {"approved_shell", "review"} /\ (env = "user" \/ cmd \notin Allowlisted))
\* A capture never runs a program its repository configures.
CaptureNeverFires == route \in CaptureRoutes => ~fired
\* A capture never writes the user's index.
CaptureLeavesUserIndex == ~userIndexWritten
\* A capture runs only on its own route: unavailable, never plain git.
CaptureStaysOnItsRoute == (caller = "capture" /\ pc = "done") => route \in CaptureRoutes
====
