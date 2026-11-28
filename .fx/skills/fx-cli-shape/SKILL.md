---
name: fx-cli-shape
description: Decide what kind of user-facing control to build in fx and what to call it, and check a change against the agreed shape. Covers top-level commands, subcommands, arguments, flags, settings keys in settings.json and .fx.json, FX_ env vars, slash commands, JSON output, and exit codes. Use when adding, renaming, deprecating, removing, or reviewing one, such as "add a command", "subcommand or flag?", "flag or setting?", "new env var", "make this configurable", "what should this be called", or a diff that touches src/builtins/commands.zig, src/core/cli/, src/core/config/, or adds an FX_ env read. Not for writing documentation prose.
---

# fx CLI shape

This skill tells you which kind of control to build and what to call it. fx follows the shape that git, gh, docker, and the Vercel CLI share, so people who know those tools can guess fx's commands. Follow these rules unless a maintainer says otherwise in the conversation.

## The shape of a command

```
fx  session  list    --all --json
    group    verb    flags

fx  session  resume  <id>
    group    verb    argument

fx  ask      "fix the login bug"  --model <id>
    verb     argument             flag
```

| Part | Job | Lasts | Example |
|---|---|---|---|
| Top-level command | A main job, or a group of jobs on one thing | One run | `fx ask`, `fx session` |
| Subcommand | One job on the group's thing | One run | `fx session resume`, `fx mcp add` |
| Argument | What the job works on | One run | `<id>`, `<name>`, `<path>` |
| Flag | How this run works: scope, amount, filter, or format | One run | `--all`, `--limit 20`, `--json` |
| Setting | A choice fx remembers | Until changed | `fast_mode` in `~/.fx/settings.json` |
| Env var | Context from CI, a wrapper, the terminal, debugging, or tests | The process | `FX_TRACE=1` |
| Slash command | The same jobs and settings inside a session | The session | `/model`, `/workspace add` |

## Ways into fx

| Way in | What it does | Takes |
|---|---|---|
| `fx`, `fx "<prompt>"` | Opens an interactive session, with or without a first prompt | The agent-run set, `--profile <name>`, and `--instances <n>` |
| `fx -c`, `fx -r [last\|<id>]`, `fx session resume` | Reopens a saved session | The agent-run set, after the target: `fx -c --model <id>` |
| `fx ask "<prompt>"` | Runs one request and exits. Scripts use this | The agent-run set, plus `--json`, `--timeout`, and `--config key=value` |
| `fx acp` | Serves an editor over ACP | The agent-run set without the 2 provider-order flags, which do nothing in ACP |
| `fx pr`, `fx issue` | Runs the agent on a pull request or an issue | The agent-run set, plus `--create` |
| Every other command | Does one job without the agent, such as `fx status` | Only its own flags |

A flag goes in one of 2 places:

- **Launch-wide flags go before the command**, because they shape the whole launch, as in `git -C dir log`: `--add-dir`, `--no-additional-dirs`, `--context-limit`, and `--tool-placement`.
- **Agent-run flags go after the command**: `--model`, `--provider`, `--effort`, `--fast`, `--ultrafast`, `--provider-order`, `--provider-strict`, and `--permission-mode`. Every way in that runs the agent takes the whole set, so a new agent-run flag is added to the set once and works everywhere.

A new way in is a new top-level command, and it takes the whole agent-run set. The "Ways into fx" section of [references/rules.md](references/rules.md) has the error hints and the rules for the first prompt.

## Pick the mechanism

Ask in order, and stop at the first yes:

1. Is it a job people do? Make it a subcommand of the group for that thing.
2. Is it the thing the job works on? Make it an argument.
3. Is it a secret? Use the credential store through `fx login`, with an env var only for CI. Never a flag, which shows in `ps` and shell history, and never `.fx.json`.
4. Does it change how one run works? Make it a flag.
5. Should fx remember it? Make it a setting, plus a flag with the same name for one run.
6. Should a team share it, and is it safe when an untrusted repo sets it? It may also go in `.fx.json`, with a maintainer's approval.
7. Does it come from CI, a wrapper, the terminal, debugging, or tests? Make it an env var. An env var for a setting uses the setting's name, as `FX_MODEL` pins the model for a whole CI job.
8. Is it unfinished? Make it an `experimental.<name>` setting.

### Subcommand or flag

A different job is a subcommand. The same job done another way is a flag.

| You want | Build | Why |
|---|---|---|
| List the saved sessions | `fx session list` | A job on sessions |
| List sessions from every workspace | `fx session list --all` | Same job, wider scope |
| Get the list as JSON | `fx session list --json` | Same job, other format |
| Resume one session | `fx session resume <id>` | Another job on one session |
| Pick one of several values | `fx usage --period <today\|7d\|month>` | One flag takes the value |

`fx session list` is the planned full form of today's `fx sessions ls`.

Wrong shapes, with made-up examples:

- A flag that does a job: `fx session --delete <id>`. Make it `fx session remove <id>`.
- A subcommand that only changes format, scope, or amount: `fx session list-json`. Make it a flag.
- One flag per value: `--today`, `--week`, `--month`. Make one flag that takes the value.
- A value in a flag's name: `--resume-<id>`. Make it `--resume <id>`.

### Top-level command or subcommand

When the job acts on a thing that already has a group, make it a subcommand. That is almost always the answer.

A new top-level command needs a maintainer's approval, and one of these must be true:

- It is a main job that people start often and that belongs to no group, like `fx ask`, `fx login`, and `fx upgrade`.
- It is a new kind of thing with 2 or more jobs, so it becomes a group, like `fx workspace` with `list`, `add`, `remove`, and `clear`.

A thing with 1 job is a plain command with flags. First check whether a flag on an existing command covers the need, such as a scope flag on `fx usage` instead of a new `fx stats`. Also, `fx "<prompt>"` starts a session, but a word that names a command runs the command, so never use a word that people type as a whole prompt.

## Name it

- **Groups use the singular noun**: `fx session`, `fx workspace`, `fx config`, as in `docker container` and `gh pr`. Where people already type the plural, it stays as an alias of the same group: `fx sessions`, `fx models`. Help shows the singular.
- **Every group uses the same verbs**: `list`, `show`, `add`, `remove`, `get`, `set`, `unset`, `clear`. Help shows the full word, and the short Unix word works too: `ls` for `list`, `rm` for `remove`. gh, docker, and the Vercel CLI accept both. So `fx sessions ls` and `fx session list` run the same job.
- **A bare group runs its list** when listing changes nothing: `fx config` runs `fx config list`.
- **One concept has one name on every surface**, and only the case changes:

| Surface | Case | Example |
|---|---|---|
| Setting key and JSON field | snake_case | `permission_mode` |
| Flag | kebab-case | `--permission-mode` |
| Env var | `FX_` plus upper snake case | `FX_PERMISSION_MODE` |
| Slash command | `/` plus the setting or group name | `/permissions` |

A flag or env var for a setting takes the setting's name: `session_titles` gets `--session-titles`, `--no-session-titles`, and `FX_SESSION_TITLES`, never `--no-titles`. Read [references/decided-names.md](references/decided-names.md) before you name anything, and reuse what is there.

## Rules agents get wrong

- **Run flags never save, and setter commands do.** `fx ask --model <id>` changes only that run. A command whose whole job is to change something saves it and prints one line that names the value and the file: `fx upgrade --channel dev`, `fx provider codex`, `fx login`, and `fx teams`.
- **Flag syntax.** `--x value` and `--x=value` both work, a boolean pairs `--x` with `--no-x`, and when flags repeat or conflict the last one wins.
- **Env vars carry context, not preferences.** To change a setting for one `fx ask` run, use `--config key=value`.
- **Output.** Results go to stdout and diagnostics to stderr. A command that prints data takes `--json`, and its fields are only added. Exit 0 means success, 1 means the work failed, and 2 means the command line is wrong.
- **Renames never break users.** The old name keeps working for at least 2 releases and 30 days, with a warning that names its replacement.

[references/rules.md](references/rules.md) has these rules in full, and the rest: experiments, slash commands, precedence, scopes, and error text.

## Built today and planned

Design toward the planned shape, but never tell a user to run something that does not exist. When unsure, run `./zig-out/bin/fx <command> --help`.

| Planned | Today |
|---|---|
| One `fx session` group, also reached as `fx sessions` | 2 groups: `fx session` reads, resumes, and recovers one session, and `fx sessions` lists and converts |
| `fx model`, also reached as `fx models` | Only `fx models` |
| `ls` and `rm` in every group, declared in the command specs | `ls` only in `fx sessions` and `fx models`, through a hand-written check. `list` only in `fx config`, `fx mcp`, and `fx workspace` |
| An Experimental section in `/settings` | None |

## Workflow

1. List every control the change adds, renames, or removes. For a diff, run [scripts/surface_diff.sh](scripts/surface_diff.sh) from the repo root.
2. Walk each one through "Pick the mechanism", and name it from an existing name: search `src/core/config/settings_keys.zig`, `src/builtins/commands.zig`, and decided-names.md.
3. Check it against its section in [references/rules.md](references/rules.md).
4. Find the files to change and the traps in [references/implementation.md](references/implementation.md).
5. Run `python3 -m scripts.check_cli_shape`, the shape check CI runs.
6. Report any conflict or needed approval first. Then give each control, its mechanism, its name on each surface, the rule behind each choice, and what is not built yet.

When a request breaks a rule, say so first: name the rule, give its reason, and offer the version that follows the rules. Build the requested version only if a maintainer approves the exception. When you review a diff, report shape problems next to bugs.

## Stop and ask a maintainer

Ask before you:

- add a top-level command, a stable env var, or a project-safe setting;
- rename or remove a stable control: `fx ask --json` fields, ACP behavior, or env vars documented on fx.sh;
- make an exception to these rules;
- invent a rule for something they do not cover, such as keyboard shortcuts, the `@`, `$`, and `!` prompt shortcuts, `--quiet`, `--verbose`, `--dry-run`, signals, or file-write safety.

When the rules do not cover a case, copy an open standard first, such as `AGENTS.md`, MCP's `mcp.json`, or `NO_COLOR`, then git, gh, and docker, and then ask.

## References

- [references/rules.md](references/rules.md): every rule by mechanism, with what is built.
- [references/decided-names.md](references/decided-names.md): names already settled.
- [references/implementation.md](references/implementation.md): where each control lives in the code, and the traps.
- [scripts/surface_diff.sh](scripts/surface_diff.sh): the controls a diff adds or removes. Run it with `--help`.
