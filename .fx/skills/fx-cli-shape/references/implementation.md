# Implementation

Where each control lives in the code, and the traps that break a change. Read it before you write the code for a control. [rules.md](rules.md) says what the control must do; this file says where to put it.

## Files that change

| Control | Files |
|---|---|
| Command or subcommand | The command kind in `src/core/slash_commands/command_specs.zig`, its spec in `src/builtins/commands.zig`, and its dispatch in `src/core/cli/cli_surface.zig`, as `AGENTS.md` describes under "Adding a Command" |
| Flag | The command's `OptionDoc` list in `src/builtins/commands.zig` and the field in its parser's flag enum |
| Setting | Its entry in `src/core/config/settings_keys.zig`, its parsing in `src/core/config/config_runtime.zig`, and the `fx config` lists in `src/core/cli/cli_config.zig` |
| Env var | Its row in `scripts/cli_shape_registry.json`, and `src/core/config/env_settings.zig` when it overrides a setting |
| Run option, such as the model | Its row in `run_options` in `scripts/cli_shape_registry.json` |
| Any of them | `tests/e2e/cli.test.ts`, and the fx.sh page for that surface |

A command's `OptionDoc` list drives its help, its flag parsing, and its completion, so a flag added there reaches all 3. Subcommand words are listed in the spec for help and completion, but each command's parser matches them itself. After a change, run `./zig-out/bin/fx <command> --help` and the command itself.

## Ways in

- The agent-run set is generated once by `agentRunOptions` in `src/builtins/commands.zig` and parsed by `src/core/cli/agent_run_flags.zig`. Add a new agent-run flag there, and every way in that runs the agent gets it. `fx acp` takes the set without the 2 provider-order flags.
- The flags before a command are `launch_options`: `launch_wide_options` first, then the flags that plain `fx` and the resume words read. A new launch-wide flag goes in `launch_wide_options`, and every launch flag needs a `top_level_flags` row; a test in `commands.zig` checks both lists in both directions.
- The resume words `-c`, `--continue`, `-r`, and `--resume` read launch flags after their target, as `launchFlagFailure` in `src/core/cli/cli_surface.zig` does. `fx session resume` reaches the same resume path.
- The placement hints come from `src/core/cli/flag_placement.zig` for a launch-wide flag after a command, and from `cli_surface.zig` for an agent-run flag before one. Reuse them for a new way in rather than writing new text.

## Commands and subcommands

- `SubcommandDoc` has no `aliases` field yet; only `TopLevelSpec` has one. Today `ls` works because `sessionListArgs` and `modelsListArgs` in `src/core/cli/cli_surface.zig` skip it by hand. When you build the planned `ls` and `rm` aliases, add the field to `SubcommandDoc` so help and completion know the short word, and match it in the command's parser. Do not add another hand-written check.
- A subcommand offers only the flags in its own `options`, plus `--help`, in completion. When it takes its parent's flags, declare them on it, as `config list` and `get` and `login vercel` do; otherwise Tab stops offering them. Set `settable_key` on a `<key>` word that takes only the keys `fx config set` changes.
- Adding or removing a slash command changes the `/help` catalog count, which tests write as literals: `Commands <n>` in unit and E2E tests, `waitForHelpMenu(session, <n>)` in the E2E tests, and the `helpCatalogCount` assertion in `src/core/slash_commands/command_specs.zig`. Search `src` and `tests` for the old count and update every one; a missed one fails a unit test or a TUI test.
- Remove a slash command that only prints a placeholder rather than hiding it, since a hidden command must be internal or deprecated. Add its name to the router's `parse rejects removed slash commands` test in `src/core/slash_commands/command_router.zig`, which uses the built-in registry, so the name can't come back by accident.

## Flags

- Every command and slash command reads its flags through `cli_flags.Parser` in `src/core/cli/cli_flags.zig`, from the same `OptionDoc` list its help renders. The global flags before a command read `launch_options` in prefix mode, which stops at the first argument it doesn't own.
- To add a flag, add an `OptionDoc` to the command's list and a field to that command's flag enum in its parser. `cli_flags.idTable` fails the build when the list and the enum disagree in either direction, so a flag can't be parsed and missing from help. When subcommands take different flags, give each list its own enum or map names to one enum at compile time, as `src/core/mcp_host/verbs.zig` does. A new global flag also needs a `top_level_flags` row, and a launch-wide one goes in `launch_wide_options`; a test in `commands.zig` checks both directions, and the usage line after a launch-flag mistake is built from `launch_options`.
- Words typed in a session are plain slices, but the parser reads arguments as the CLI receives them. Copy them with `dupeSentinel` into an arena first, as `parse` in `src/core/mcp_host/verbs.zig` does for `fx mcp` and `/mcp`, rather than comparing flags by hand.
- A flag that takes a number in a range writes the range in its placeholder, as `--limit <1-100>`, so a bad value gets `--limit takes a whole number from 1 to 100, not abc`. `flagProblem` in `cli_surface.zig` writes the same text for plain and `--json` errors; don't add a separate message for one of them.
- Don't compare an argument with a flag literal by hand. CI's `python3 -m scripts.check_cli_shape` fails on it anywhere in `src/`, in either argument order or through a named constant, unless `scripts/cli_shape_registry.json` lists the flag in `hand_parsed_flags`, as it does for help and version detection and the fixed resume grammar, or the file in `hand_parsed_files`, as it does for code that reads another program's flags, such as the shell-command checks.
- The `run_options` check fails when ACP offers or accepts a config option, or libfx's `FxModelOptions` declares a field, that no row names.
- `--x value` and `--x=value` both come from the shared parser in `src/core/cli/cli_flags.zig`; don't parse either form yourself.
- When `--json` is anywhere in the arguments, a usage error goes through `writeUsageOrJsonError` in `cli_surface.zig`, built from `flagProblem`, so the JSON and plain errors carry the same text. `output_contracts.usage_exit_code` is the exit code 2.

## Settings

- `fx config get` without a scope reports the value a run uses, through `resolveSettings` in `src/core/app/app_lifecycle.zig`. A new plain setting goes in `resolved_keys` in `cli_config.zig`, or in `files_only_keys` with a reason; a unit test fails until it does.
- `.fx.json` filtering is structural: only `parseProjectSafeFields` reads project files. Every key also goes in the settings list, `src/core/config/settings_keys.zig`, marked `.profile` or `.project_safe`. That list drives the "ignored in project" warning and `fx doctor`'s unknown-key report, and the CI shape check fails if a parser reads a key it lacks.
- Full access is saved and printed as `full-access`, and `yolo` is read until fx 0.0.18, with `fx doctor` pointing it out. Only ACP's mode `_meta`, which ACP clients may read, and the fx-managed `yolo_acknowledged` key keep the old word.
- To rename a key, keep the older name in `settings_keys.zig` with `renamed_to`. The parser then reads both, with the current one winning, saving moves the old value, `fx config` accepts both spellings, and `fx doctor` reports the older name, alone or beside the current one, with the release that drops it.
- Unit tests fail when a key's kind, values, bounds, or placement disagree with what the parser accepts, or when `fx config set` writes a different type.
- `fx config get` of a key with no value prints nothing and exits 1, and with `--json` reports `ConfigKeyNotSet`. `fx config set` and `unset` write only the top level of `~/.fx/settings.json`: they refuse `--workspace` and maps, and remove the key's copies from workspace entries, because fx treats preferences there as legacy and the change must take effect.
- A value given to `fx config set` may start with a dash, as `-5` does. The value check rejects a bad one, not the flag parser.
- The first experiment adds an `experimental` group to `settings_keys.zig` with the key as its child, the key to the `fx config` writable list and `resolved_keys`, and a profile-only parser for the group in `config_runtime.zig`.

## Env vars

- Every `FX_*` name in `src/` must be registered, with a job and a stability, in `scripts/cli_shape_registry.json`, or CI fails. Known violations are listed there as exceptions, each with the change that removes it. A new exception needs a maintainer's approval; never add one to make a new control pass.
- An `FX_*` override listed in `src/core/config/env_settings.zig` shows in `fx config list`, so fx.sh documents it, and the shape check fails unless `scripts/cli_shape_registry.json` marks it `stable`.
- Every test hook starts with `FX_TEST_`; CI rejects a test hook with any other prefix, and any other variable with that prefix.
- A new `FX_*` setting override is applied where its setting is resolved: `resolveSettings` in `src/core/app/app_lifecycle.zig` for run values, or `config_runtime.applyEnvSettingOverrides` for a merged setting, which runs again after `fx ask --config` so the variable keeps beating it. List it in `env_settings.zig` too, which labels it `env:FX_NAME` in `fx config list --show-origin`.
- `main` checks `FX_HOME` once at startup through `profile_paths.useFxHome`. With `HOME` unset, its parent serves as the home folder, and `main` creates its missing parent folders before I/O is set up. Code reaches the folder only through `src/core/shared/profile_paths.zig`: `rootPath` and the named helpers build paths, and code that opens the folder without following symlinks opens `rootParent(home)` and then `rootName()`. Never join `HOME` with `.fx`. A message that names a file there writes `~/.fx/...` through `displayText`, or formats `displayRoot()`, so it says `$FX_HOME/...` when the variable is set.
- `NO_COLOR` and `TERM=dumb` are read through `src/core/shared/terminal_env.zig`. The interactive session turns off `engine.colors_enabled` before startup, so cells never take a color while bold, dim, and reverse stay. New output that styles text goes through the terminal engine, or checks `terminal_env.colorDisabled()` itself.

## Deprecations

- Build a deprecation warning from `command_specs.deprecated_until`, as `/setup` does with `"/setup " ++ command_specs.deprecated_until ++ "; use /login ..."`. Tests pin the full text, and writing the release by hand breaks when it moves.
- A warning first ships in the first release tagged after it merges, which can be later than planned: check with `git tag --contains <merge commit>`. The current set was first meant to drop in 0.0.17 but merged after v0.0.16 was cut, so 0.0.17 was its first warning release and its version bump failed the shape check until the removal moved to 0.0.18. For the same reason, merge the change that removes old spellings only after the last release that warns about them is tagged.
- `fx login vercel --api-key` pastes an AI Gateway API key. `fx setup` and `/setup` still work until fx 0.0.18 but warn: `fx setup` points to `fx login vercel --api-key`, and `/setup`, an alias of `/provider`, points to `/login` and `/provider`. Neither appears in help. Don't give "setup" a new meaning.
- Resume already has seven kept spellings. Use `--resume last` or `--resume <id>`; never add another form such as `--resume-latest`.
