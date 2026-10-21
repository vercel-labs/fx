---- MODULE GitAdmission ----
\* fx's route for an agent git command, from planning through admission to
\* execution, over every permission mode, shell environment, command form,
\* git version and repository state (src/core/shell_command/safe_git.zig).
\*
\* Contract (AGENTS.md): in auto mode safe git runs the read-only status,
\* diff, log and show forms it can express directly, in every shell profile,
\* and holds a planned command in a repository it cannot read. Every other
\* agent git inspection runs in a shell under the agent environment, which
\* turns off the programs a repository's config names for reading on git 2.31
\* and later. The documented exposure is a repository fx cannot read and git
\* older than 2.31.
EXTENDS Naturals, Sequences

CONSTANTS HoldEnabled, EnvEnabled

Modes == {"auto", "ask"}
Envs == {"clean", "user"}
\* status, diff and log stand for the forms safe git runs directly
\* (status --short, diff --stat, log --oneline -n 3). status_other is a shape
\* it cannot express, such as `git diff HEAD`. reworded is an inspection that
\* is not written as plain git, such as `cd sub && git status`.
Cmds == {"status", "status_other", "diff", "log", "reworded"}
Repos == {"clean", "poisoned", "unreadable", "mismatch", "notrepo"}
\* Repository states whose own config names a program.
Poisoned == {"poisoned", "unreadable", "mismatch"}
Allowlisted == {"status", "diff", "log"}
\* Commands whose first word is `git`, which the planner reads.
GitFirst == {"status", "status_other", "diff", "log"}
\* Safe git refuses when it cannot read the config or git would pick
\* another repository.
Refuses == {"unreadable", "mismatch"}
\* Forms that run a repository program under plain git. `git log --oneline`
\* runs none.
FiresInPlain == Cmds \ {"log"}
Verdicts == {"clear", "caution"}

VARIABLES mode, env, cmd, repo, newgit, verdict, plan, route, fired, pc, history
vars == <<mode, env, cmd, repo, newgit, verdict, plan, route, fired, pc, history>>

Init ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos
    \* Whether git reads `GIT_CONFIG_COUNT` (2.31 and later).
    /\ newgit \in BOOLEAN
    \* The security reviewer's verdict, used only on the review route.
    /\ verdict \in Verdicts
    /\ plan = "none" /\ route = "none" /\ fired = FALSE
    /\ pc = "plan" /\ history = <<>>

\* Safe git is prepared before the arguments are checked, so a refusal wins.
\* Outside auto mode, and for a command the planner does not read as git, the
\* shell decides.
PlanResult ==
    IF mode # "auto" \/ cmd \notin GitFirst THEN "dynamic_shell"
    ELSE IF repo \in Refuses THEN "unsafe_git"
    ELSE IF cmd \notin Allowlisted THEN (IF newgit THEN "unsupported_argument" ELSE "unsafe_git")
    ELSE "direct"

\* No git command is a routine auto command, so everything that is neither
\* direct nor held goes to review.
AdmitResult ==
    IF plan = "direct" THEN "direct"
    ELSE IF mode = "ask" THEN "prompt"
    ELSE IF plan = "unsafe_git" /\ HoldEnabled THEN "held"
    ELSE "review"

Plan ==
    /\ pc = "plan" /\ plan' = PlanResult /\ pc' = "admit"
    /\ history' = Append(history, "Plan")
    /\ UNCHANGED <<mode, env, cmd, repo, newgit, verdict, route, fired>>

Admit ==
    /\ pc = "admit" /\ route' = AdmitResult /\ pc' = "execute"
    /\ history' = Append(history, "Admit")
    /\ UNCHANGED <<mode, env, cmd, repo, newgit, verdict, plan, fired>>

\* The agent environment turns off the repository's programs for a shell-run
\* git when git reads it and fx can read the config.
EnvProtects == EnvEnabled /\ newgit /\ repo \notin Refuses

\* A review that clears runs the command in the shell; safe git, a held
\* command, a prompt and a cautioned review run none.
RunsShellGit == route = "review" /\ verdict = "clear"
Execute ==
    /\ pc = "execute"
    /\ fired' = (RunsShellGit /\ repo \in Poisoned /\ cmd \in FiresInPlain /\ ~EnvProtects)
    /\ pc' = "done" /\ history' = Append(history, "Execute")
    /\ UNCHANGED <<mode, env, cmd, repo, newgit, verdict, plan, route>>

Next == Plan \/ Admit \/ Execute
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos
    /\ newgit \in BOOLEAN /\ verdict \in Verdicts
    /\ pc \in {"plan", "admit", "execute", "done"}
    /\ fired \in BOOLEAN

\* G1: in auto mode, a command safe git refused is held, never run.
HoldSafety == (pc = "done" /\ mode = "auto" /\ plan = "unsafe_git") => route = "held"
\* Safe git never runs a repository program.
DirectNeverFires == route = "direct" => ~fired
\* Programs run only on the documented exposure.
ExposureOnlyDocumented ==
    fired => (route = "review" /\ (repo \in Refuses \/ ~newgit))
====
