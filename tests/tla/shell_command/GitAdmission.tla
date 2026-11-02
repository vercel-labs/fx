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
EXTENDS Naturals, Sequences

CONSTANT HoldEnabled

Modes == {"auto", "ask"}
Envs == {"clean", "user"}
Cmds == {"status", "status_other", "diff", "log"}
Repos == {"clean", "poisoned", "unreadable", "mismatch", "notrepo"}
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

VARIABLES mode, env, cmd, repo, verdict, plan, route, fired, pc, history
vars == <<mode, env, cmd, repo, verdict, plan, route, fired, pc, history>>

Init ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos
    \* The security reviewer's verdict, used only on the review route.
    /\ verdict \in Verdicts
    /\ plan = "none" /\ route = "none" /\ fired = FALSE
    /\ pc = "plan" /\ history = <<>>

\* Safe git is prepared before the arguments are checked, so a refusal wins.
PlanResult ==
    IF env = "user" \/ mode # "auto" THEN "dynamic_shell"
    ELSE IF repo \in Refuses THEN "unsafe_git"
    ELSE IF cmd \notin Allowlisted THEN "unsupported_argument"
    ELSE "direct"

AdmitResult ==
    IF plan = "direct" THEN "direct"
    ELSE IF mode = "ask" THEN "prompt"
    ELSE IF plan = "unsafe_git" /\ HoldEnabled THEN "held"
    ELSE IF cmd \in Reversible THEN "approved_shell"
    ELSE "review"

Plan ==
    /\ pc = "plan" /\ plan' = PlanResult /\ pc' = "admit"
    /\ history' = Append(history, "Plan")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, route, fired>>

Admit ==
    /\ pc = "admit" /\ route' = AdmitResult /\ pc' = "execute"
    /\ history' = Append(history, "Admit")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, plan, fired>>

\* Plain git, reached unreviewed or through a review that clears, runs the
\* repository's programs; safe git, a held command, a prompt and a cautioned
\* review run none.
RunsPlainGit == route = "approved_shell" \/ (route = "review" /\ verdict = "clear")
Execute ==
    /\ pc = "execute"
    /\ fired' = (RunsPlainGit /\ repo \in Poisoned /\ cmd \in FiresInPlain)
    /\ pc' = "done" /\ history' = Append(history, "Execute")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, plan, route>>

Next == Plan \/ Admit \/ Execute
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos /\ verdict \in Verdicts
    /\ pc \in {"plan", "admit", "execute", "done"}
    /\ fired \in BOOLEAN

\* G1: in auto mode, a command safe git refused never reaches plain git.
HoldSafety == (pc = "done" /\ mode = "auto" /\ plan = "unsafe_git") => route # "approved_shell"
\* Safe git never runs a repository program.
DirectNeverFires == route = "direct" => ~fired
\* Programs run only on the documented shell path.
ExposureOnlyDocumented == fired => (route \in {"approved_shell", "review"} /\ (env = "user" \/ cmd \notin Allowlisted))
====
