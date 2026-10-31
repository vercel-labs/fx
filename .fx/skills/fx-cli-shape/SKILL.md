---
name: fx-cli-shape
description: Choose the mechanism and the names for any user-facing control in fx, and check changes against the agreed shape. Covers subcommands, arguments, flags and options, settings keys in settings.json and .fx.json, environment variables (FX_ env vars), slash commands, JSON output, and exit codes. Use when adding, renaming, deprecating, removing, or reviewing one, for example "add a flag", "add an option", "new env var", "make this configurable", "let users turn on X", "add a slash command", "deprecate this flag", "should this be a flag or a setting", or a diff that touches src/builtins/commands.zig, src/core/cli/, src/core/config/, or adds an FX_ env read. Not for parser internals or writing documentation prose.
---

# fx CLI shape

fx follows git and Unix conventions for how people and scripts control it. Each concept gets one mechanism and one name, so anyone who knows git can guess the command, flag, or setting. Use this skill to pick the mechanism for a new control, name it on every surface, and check a change before it lands. The maintainers agreed on these rules; follow them unless a maintainer says otherwise in the conversation.

## Current versus target

One piece the rules rely on isn't built yet: the Experimental section of `/settings`. Design new work toward them, but never tell a user to run something that doesn't exist yet. Check `./zig-out/bin/fx help` and `./zig-out/bin/fx <command> --help` when unsure. When a target piece is missing, use the nearest current pattern and say what's missing.

## Decision order

Ask in order and stop at the first yes:

1. Is it an action? Use a subcommand, named as a verb or a noun plus a verb. Inside a session, a slash command with the same name.
2. Is it what the action works on? Use an argument.
3. Is it a secret? Use the credential store, with an env var only for CI. Never a flag, which shows up in `ps` and shell history, and never `.fx.json`.
4. Does it matter for this run only? Use a flag.
5. Should it persist? Use a setting, plus a flag with the same name for one-off overrides.
6. Is it safe for an untrusted repo to set, and useful for a team to share? It may also be project-safe in `.fx.json`, with a maintainer's approval.
7. Is it set by CI, a wrapper, a terminal, debugging, or tests? Use an env var in the right namespace.
8. Is it unfinished? Use an `experimental.<name>` setting.

## Core rules

These are the rules agents most often get wrong. [references/rules.md](references/rules.md) has the full set, with what's built today.

**Extend before adding.** Before adding a command, flag, setting, or env var, check whether extending an existing command or control covers the need, for example a scope flag on `fx usage` instead of a new `fx stats`. Every new control is a promise that costs a deprecation to take back. When a new one is still the right call, say why the existing one can't be extended.

**Names.** One concept, one name, cased per surface: snake_case for settings and JSON (`permission_mode`), kebab-case for flags (`--permission-mode`), `FX_` plus upper snake case for env vars (`FX_PERMISSION_MODE`). Values use the same words everywhere. Before naming anything, check [references/decided-names.md](references/decided-names.md) and reuse what's there. A second spelling for an existing concept is the drift this skill exists to stop.

**Run flags never save; setter commands do.** A flag that shapes a run, on `fx`, `fx ask`, `fx pr`, or `fx acp`, affects only that run. git works the same way: `git pull --rebase` doesn't save `pull.rebase`. A setter command, whose whole job is to change something, saves what it changes, and its flags say what to save: `fx upgrade --channel dev` keeps the dev channel for later upgrades, like `rustup default stable`. Other setters are `fx provider codex`, `fx login`, and `fx teams`. A setter should print one line naming the value and the file it went to. If asked for a run flag that saves, lead with the conflict and the compliant path: a setter command, or `/model` in a session, which saves the default model to the profile.

**Flag syntax.** `--x value` and `--x=value` both work. Booleans pair `--x` with `--no-x`. When a flag repeats or conflicts, the last one wins, so wrappers and aliases can override earlier flags. An enum is one flag that takes the value. No value goes inside a flag name.

**Flag placement.** Agent-run flags (`--model`, `--provider`, `--effort`, `--fast`, `--ultrafast`, `--provider-order`, `--provider-strict`, `--permission-mode`) go after the subcommand, and every command that runs the agent accepts the whole set, parsed by `src/core/cli/agent_run_flags.zig`. `fx acp` leaves out the two provider-order flags, because ACP sessions don't apply gateway provider routing. Plain `fx` takes them directly. Only launch-wide flags such as `--add-dir` go before a subcommand, as in `git -C dir log`.

**Env vars are for context, not preferences.** A setting gets a named env override only when CI or wrapper scripts need it for a whole process tree, and the override uses the setting's name: `collapse_tool_calls` becomes `FX_COLLAPSE_TOOL_CALLS`, never a shorter invented name. Other settings take `fx ask --config key=value` for one run. Diagnostics use `FX_TRACE*` and `FX_RECORD*`, tests use `FX_TEST_*`, and `FX_HOME` moves fx's home. Respect `NO_COLOR` and `TERM=dumb`.

**Experiments are settings.** An unfinished feature is `experimental.<name>`, off by default and profile-only. It never gets its own flag or env var, so finishing or dropping it removes nothing people type.

**Project files are untrusted.** Anyone who can commit to a repo controls its `.fx.json`, so it accepts only project-safe keys. Permission settings, credentials, and experiments are never project-safe.

**Slash commands use the setting's name.** A slash command that changes a setting uses that setting's name and values (`/fast on` writes `fast_mode`), like vim's `:set number`. A slash action uses the CLI command's name (`/workspace add` matches `fx workspace add`).

**Output.** Results go to stdout and diagnostics to stderr. Every command that prints data accepts `--json`, and its fields are only added; a shape that must change goes behind `--json=v2`. Don't add a `schema_version` field: commands such as `fx status --json` name their shape with `kind`. Usage errors exit with 2 and real failures with 1. Errors name the bad input and suggest the closest match.

**Precedence.** Highest first: managed by an administrator (reserved, not built), flag, env var, the profile's entry for this folder, the profile, the project's `.fx.json`, the default.

**Scopes.** Commands that choose where a setting lives use `--global` and `--workspace`, plus `--project` only when they write a committed file.

**Change over time.** Every control is stable, experimental, deprecated, or internal. Renaming or removing a stable control keeps the old name working with a warning for at least two releases and 30 days. The warning names the release that drops it, `old_spelling_removal` (0.0.17 for the current set), and CI fails once fx reaches it. Help and completion show only the new name.

## Workflow

1. List every control the change adds, renames, or removes. For a diff, run [scripts/surface_diff.sh](scripts/surface_diff.sh) from the repo root; it prints lines such as `+ flag --fast-diff  src/builtins/commands.zig`. Matches come from string literals, so skip test fixtures.
2. Walk each control through the decision order.
3. Name it on every surface where it appears, starting from an existing name for the same concept. Search the settings list in `src/core/config/settings_keys.zig`, the specs in `src/builtins/commands.zig`, and decided-names.md. A one-run flag or env override for an existing setting takes that setting's name: for the `session_titles` setting it would be `--session-titles` and `--no-session-titles`, plus `FX_SESSION_TITLES` if an env var is warranted, never `--no-titles`.
4. Check it against the matching section of rules.md.
5. List what else must change: the spec and help text in `src/builtins/commands.zig`, which completion also reads; parsing in `src/core/cli/`; for a setting, its `settings_keys.zig` entry, parsing in `src/core/config/config_runtime.zig`, and the `fx config` lists in `src/core/cli/cli_config.zig`; `tests/e2e/cli.test.ts`; and the fx.sh page for that surface.
6. Report, in this order: any conflict or approval the request needs; then the control, its mechanism, its name on each surface, and the rule behind each choice; then what else changes and what isn't built yet.

When a request conflicts with a rule or needs a maintainer's approval, lead with the conflict: name the rule, say why it exists, and give the compliant version first. Describe the requested version only as a conditional, to build only if a maintainer approves the exception. Don't quietly build the non-compliant version, and don't quietly refuse.

When reviewing a diff, report shape findings alongside bug findings. A change can be broken and misnamed at once, and fixing the bug doesn't fix the name.

## Stop and ask

Ask a maintainer before:

- adding a new top-level command, a new stable env var, or a new project-safe setting;
- renaming or removing a stable control: `fx ask --json` fields, ACP behavior, or env vars documented on fx.sh;
- making any exception to a rule above.

Ask before inventing a rule for something these rules don't cover: keyboard shortcuts, prompt shortcuts (`@`, `$`, `!`), verbosity levels (`--quiet`, `--verbose`), `--dry-run`, Ctrl+C and signals, and file-write safety.

## Gotchas

- Every command and slash command reads its flags through `cli_flags.Parser` in `src/core/cli/cli_flags.zig`, from the same `OptionDoc` list its help renders. The global flags before a command read `launch_options` in prefix mode, which stops at the first argument it doesn't own.
- To add a flag, add an `OptionDoc` to the command's list and a field to that command's flag enum in its parser. `cli_flags.idTable` fails the build when the list and the enum disagree in either direction, so a flag can't be parsed and missing from help. When subcommands take different flags, give each list its own enum or map names to one enum at compile time, as `src/core/mcp_host/verbs.zig` does. A new global flag also needs a `top_level_flags` row, and a launch-wide one goes in `launch_wide_options`; a test in `commands.zig` checks both directions, and the usage line after a launch-flag mistake is built from `launch_options`.
- Words typed in a session are plain slices, but the parser reads arguments as the CLI receives them. Copy them with `dupeSentinel` into an arena first, as `parse` in `src/core/mcp_host/verbs.zig` does for `fx mcp` and `/mcp`, rather than comparing flags by hand.
- A subcommand offers only the flags in its own `options`, plus `--help`, in completion. When it takes its parent's flags, declare them on it, as `config list` and `get` and `login vercel` do; otherwise Tab stops offering them. Set `settable_key` on a `<key>` word that takes only the keys `fx config set` changes.
- A flag that takes a number in a range writes the range in its placeholder, as `--limit <1-100>`, so a bad value gets `--limit takes a whole number from 1 to 100, not abc`. `flagProblem` in `cli_surface.zig` writes the same text for plain and `--json` errors; don't add a separate message for one of them.
- `fx config get` without a scope reports the value a run uses, through `resolveSettings` in `src/core/app/app_lifecycle.zig`. A new plain setting goes in `resolved_keys` in `cli_config.zig`, or in `files_only_keys` with a reason; a unit test fails until it does.
- Don't compare an argument with a flag literal by hand. CI's `python3 -m scripts.check_cli_shape` fails on it anywhere in `src/`, in either argument order or through a named constant, unless `scripts/cli_shape_registry.json` lists the flag in `hand_parsed_flags`, as it does for help and version detection and the fixed resume grammar, or the file in `hand_parsed_files`, as it does for code that reads another program's flags, such as the shell-command checks.
- Run `./zig-out/bin/fx <command> --help` and the command itself after changing a flag.
- `.fx.json` filtering is structural: only `parseProjectSafeFields` reads project files. Every key also goes in the settings list, `src/core/config/settings_keys.zig`, marked `.profile` or `.project_safe`. That list drives the "ignored in project" warning and `fx doctor`'s unknown-key report, and the CI shape check fails if a parser reads a key it lacks.
- Every `FX_*` name in `src/` must be registered, with a job and a stability, in `scripts/cli_shape_registry.json`, or CI fails. Known violations are listed there as exceptions, each with the change that removes it. A new exception needs a maintainer's approval; never add one to make a new control pass.
- `-c` already means continue, so git's `-c key=value` can't be copied. The one-run override is `fx ask --config key=value`.
- Full access is saved and printed as `full-access`, and `yolo` is read until fx 0.0.17, with `fx doctor` pointing it out. Only ACP's mode `_meta` and the fx-managed `yolo_acknowledged` key keep the old word.
- Build a deprecation warning from `command_specs.deprecated_until`, as `/setup` does with `"/setup " ++ command_specs.deprecated_until ++ "; use /login ..."`. Tests pin the full text, and writing the release by hand breaks when it moves.
- `fx login vercel --api-key` pastes an AI Gateway API key. `fx setup` and `/setup` still work until fx 0.0.17 but warn: `fx setup` points to `fx login vercel --api-key`, and `/setup`, an alias of `/provider`, points to `/login` and `/provider`. Neither appears in help. Don't give "setup" a new meaning.
- Resume already has seven kept spellings. Use `--resume last` or `--resume <id>`; never add another form such as `--resume-latest`.
- Every test hook starts with `FX_TEST_`; CI rejects a test hook with any other prefix.

## References

- [references/rules.md](references/rules.md): every rule by mechanism, marked as built or planned. Read it when choosing names or reviewing a change in detail.
- [references/decided-names.md](references/decided-names.md): names already settled. Read it before naming anything near resume, permissions, scopes, sound, the status line, experiments, aliases, setup, or login.
- [scripts/surface_diff.sh](scripts/surface_diff.sh): lists the env vars, flags, commands, slash commands, and settings keys a diff adds or removes. Run `scripts/surface_diff.sh --help` for options.
