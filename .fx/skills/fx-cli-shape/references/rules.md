# fx control rules

The full rules behind SKILL.md, by mechanism. Each rule says what fx does today, or names the target when it is not built. Design toward the target, but never present it as if it exists. [implementation.md](implementation.md) says where each rule lives in the code.

## Ways into fx

SKILL.md lists the ways in, the flags each one takes, and where flags go. These are the details:

- A launch-wide flag after a command fails with a hint: `fx ask: unknown flag --add-dir; it goes before the command: fx --add-dir <path> ask`. An agent-run flag before a command fails with the reverse hint: `fx: put agent-run flags after the command, as in fx ask --model <id>`. The agent-run set includes the `--no-` forms and the permission shortcuts `--ask`, `--auto`, `--full-access`, and `--yolo`.
- A new way in that runs the agent takes the whole agent-run set. Leave a flag out only where it can do nothing, as ACP does with `--provider-order` and `--provider-strict`.
- `fx "<prompt>"` takes one quoted argument, as other coding agents' CLIs do, with flags before or after it. It can also follow a resume target: `fx -c "<prompt>"` or `fx -r <id|last> "<prompt>"`. Several unquoted words fail with `fx: put the prompt in quotes: fx "fix the login bug"`, and a word one or two edits from a command name, such as `stauts`, gets a suggestion. So every new command name is a word that can no longer start a session.
- Scripts use `fx ask`. fx never prompts without a terminal: it fails with a message that names the flag that avoids the prompt.
- Flags that people bring from other agents get a pointer, not an alias: `fx -p` and `fx --print` fail with exit 2 and say to use `fx ask "<prompt>"`.
- `fx foo` never runs an `fx-foo` program from `PATH`. Skills and MCP are the extension points.

## Names

- One concept has one name. Each surface writes it in its own case, as the table in SKILL.md shows. libfx and ACP options use their host language's case, such as `permissionMode`.
- Values use the same words everywhere, in storage too. Permission mode is `ask`, `auto`, or `full-access`; [decided-names.md](decided-names.md) lists the legacy `yolo` spellings.
- Boolean env values accept `1`/`0`, `true`/`false`, `on`/`off`, and `yes`/`no`, trimmed and case-insensitive.
- Keys that other coding agents' project files already use keep their spelling, so the same files work with fx: `enabledMcpjsonServers`, `disabledMcpjsonServers`, and `enableAllProjectMcpServers`. `statusLine` was the one camelCase key fx chose itself; fx reads it until 0.0.18 and writes only `status_line`.

## Precedence

Highest first:

1. Managed by an administrator. Reserved; not built yet.
2. A flag on this command.
3. An env var.
4. The profile's entry for this folder, `workspaces["<path>"]`.
5. The profile, `~/.fx/settings.json`.
6. The project's `.fx.json`, project-safe keys only.
7. The built-in default.

Run flags and env vars never save; setter commands do (see Flags). Every effective value reports its layer: `fx config list --show-origin` shows each file value and, last, each documented `FX_*` setting override that is set, as `env:FX_NAME`.

## Commands

SKILL.md has the shape, the choice between a subcommand and a flag, and the group and verb names. These are the rest:

- A command that only shows things never changes anything. A setter command, whose whole job is to change a setting, may save: `fx provider codex`, `fx teams`.
- Existing aliases stay: `credits`/`balance`, `upgrade`/`update`, `/credits`/`/balance`, `/quit`/`/exit`, `/image`/`/img`, `fx sessions`, and `ls` in `fx sessions` and `fx models`.
- User aliases are planned as `alias.<name>` settings that work as `fx <name>` and `/<name>`. An alias never shadows a built-in command. Until they exist there is no `/alias` command.
- A hidden command is either internal, and labeled so in its spec, or deprecated. `fx replay` is hidden and labeled as a developer tool. A command that does nothing yet is removed rather than hidden.
- A new top-level command, including a new way in, needs a maintainer's explicit approval.

## Flags

- Long flags are kebab-case. Short flags are scarce and keep one meaning: `-h` help, `-v` version, `-c` continue, `-r` resume. A short flag means the same as its long form: with no value, `-r` and `--resume` open the session picker, `last` opens the newest session, and an ID opens that one (`--resume=<id>` works too). Because `-c` is taken, git's `-c key=value` can't be copied; the one-run override is `fx ask --config key=value`.
- `--x value` and `--x=value` both work on every command.
- A boolean pairs `--x` with `--no-x`.
- When a flag repeats or conflicts, the last one wins, on every command, so wrappers and aliases can override earlier flags. `--fast --no-fast` means Fast mode off; `--fast --ultrafast` means Ultrafast mode.
- An enum is one flag that takes the value: `--permission-mode <ask|auto|full-access>`. Its shortcut aliases stay: `--ask`, `--auto`, `--full-access`, and `--yolo`.
- No flag carries a value in its name. `--resume-<id>` was removed and fails with a hint naming `--resume <id>`.
- A flag that shapes a run affects only that run and never saves anything, as `git pull --rebase` does not save `pull.rebase`. A setter command saves what it changes, and its flags name what to save: `fx upgrade --channel dev` switches the channel for later upgrades too. Keep it that way rather than making `--channel` one-time, because auto-upgrade reinstalls whenever the running build's channel differs from the saved one. A setter prints one line that names the value and the file, as `Release channel set to dev in ~/.fx/settings.json.` A bad value names itself: `fx upgrade: invalid value for --channel: nightly`. To save a default model, use `/model` in a session.
- An unknown or invalid flag fails with a message naming it. Every accepted flag appears in help unless it is a hidden deprecated spelling, because the parser reads the same list help renders. Never compare a flag by hand; CI's shape check fails on it anywhere in `src/`.

## Settings

- Keys are snake_case; nested groups are fine (`sound.turn_end`).
- `.fx.json` accepts only project-safe keys. Today they are `context`, `max_agent_steps`, `max_tool_result_bytes`, `provider_order`, and `provider_strict`. A new project-safe key needs a maintainer's approval, because anyone who can commit to a repo controls that file. Permission settings, credentials, and experiments are never project-safe.
- Every key goes in the settings list, `src/core/config/settings_keys.zig`, marked `.profile` or `.project_safe`, with its kind, a one-line description, and its allowed values or bounds. A project file that sets a `.profile` key is ignored with a warning. `fx doctor` reports keys missing from the list, with the closest known one. A retired key stays listed as `.retired`, so it is ignored without a report, and an older form that fx still reads gets `superseded_by`.
- `fx config schema` builds the JSON Schema for `settings.json`, and `--project` the one for `.fx.json`, from that list. When the schema output changes, refresh the copies fx.sh serves at `https://fx.sh/schemas/settings.json` and `https://fx.sh/schemas/fx.json`.
- Scope words are `--global` (the profile), `--workspace` (this folder's entry in the profile), and `--project` only for commands that write a committed file, such as `fx mcp` with `.mcp.json`. [decided-names.md](decided-names.md) lists the older words that still work.
- `fx config` works like `git config`. `list` shows the values set in each layer as `key=value` with dotted keys, lowest precedence first, and `--show-origin` names each value's layer. `get <key>` prints the value a run uses, defaults included. `set` and `unset` change plain preferences in `~/.fx/settings.json` and print one line that names the key, the value, and the file.
- `fx config` refuses the security and account keys and points to the command that owns each, because an agent can run `fx config` through its shell tool and must not change `permission_mode` or `review_model` that way. It never writes committed files and never handles credentials.
- Unknown keys are ignored at startup, reported by `fx doctor` and `fx config list`, and rejected by `fx config get` and `set`.
- Data that fx writes for itself, such as `~/.fx/sessions/`, is state, never a setting.

## Env vars

Each env var has one job and that job's namespace:

| Job | Namespace | Example |
|---|---|---|
| Override a setting for one process | `FX_<SETTING>`, same name and values as the setting | `FX_MODEL` |
| CI credentials | The provider's own name | `AI_GATEWAY_API_KEY` |
| Location of fx's home | `FX_HOME` | `FX_HOME=/tmp/fx-test` |
| Integration with the surroundings | `FX_<INTEGRATION>` | `FX_HERDR=0`, `FX_NO_OPEN_BROWSER=1` |
| Diagnostics | `FX_TRACE*`, `FX_RECORD*`, `FX_DEBUG_*` | `FX_TRACE=1` |
| Test hooks | `FX_TEST_*` | Every test hook uses it, and nothing else does |
| Unix standards | As defined | `NO_COLOR`, `TERM`, `HOME` |

- A setting gets a named env override only when CI jobs or wrapper scripts need it for a whole process tree. For one `fx ask` request, `--config key=value` overrides any key `fx config set` takes, with the same checks. Like `git -c`, it is the top settings layer: it beats every settings file, while dedicated flags and `FX_*` variables still beat it. It repeats, the last value for a key wins, and it never saves. Interactive sessions don't take it; they change settings with `/settings` and slash commands.
- An override uses the setting's name: `collapse_tool_calls` becomes `FX_COLLAPSE_TOOL_CALLS`, never an invented short name.
- No unprefixed names except Unix standards and the variables of third-party integrations, which are listed under `external_env` in `scripts/cli_shape_registry.json`.
- Every `FX_*` name in `src/` is registered in `scripts/cli_shape_registry.json` with its job and stability, and the ones documented on fx.sh are `stable`. CI's shape check fails on an unregistered or stale name, and on an override that `fx config list` reports but that isn't `stable`.
- An env var shapes context. It never changes what a command does.
- `FX_HOME` is an absolute path that replaces `~/.fx` for everything fx keeps there; the OS keychain stays shared. It can't be the home folder itself, because fx keeps its folder private. Help text still says `~/.fx`.
- Respect `NO_COLOR` and `TERM=dumb` on every output path; `NO_COLOR` counts only when it is not empty. Help and `fx ask` drop color for either. The interactive session drops color for `NO_COLOR`, and refuses `TERM=dumb` with a message that points to `fx ask`.

## Slash commands

- A slash command that does a job uses the CLI command's name and verbs: `/workspace add` matches `fx workspace add`.
- A slash command that changes a setting uses the setting's name and values: `/fast on` writes `fast_mode`. This follows vim, where `:set number` matches `set number` in `.vimrc`. `/model` is a picker for model and effort, which is a job.
- A toggle accepts explicit values as well as no argument: `/fast [on|off]`, like `/ultrafast [on|off|status]`.
- A slash command that changes a setting saves to the profile and names the file in its confirmation.

## Output, errors, and exit codes

- Results go to stdout; progress and diagnostics go to stderr.
- Every command that prints data accepts `--json`. Failures share one shape: `{"kind": ..., "error": ..., "code": ...}`, as `fx session last --json` does. That includes usage errors: when `--json` is anywhere in the arguments, a bad flag or extra argument prints that shape on stdout with exit 2 and nothing on stderr, and its `error` is the same text the plain error names.
- JSON fields are only added. If a shape must change, the new shape is opt-in behind a versioned flag such as `--json=v2`, as git's `--porcelain=v2` is. Don't add a `schema_version` field: commands such as `fx status`, `fx sessions`, and `fx session` name their JSON shape with `kind`.
- Exit codes: 0 for success, 1 when the work fails, 2 when the command line is wrong.
- An error says what happened, which input caused it, and what to do, and suggests the closest match for a typo: `fx status: unknown flag --jsno (did you mean --json?)`. A mistyped command, subcommand, or launch flag gets the same, as `fx stauts` suggests `status`. A number outside the range in its placeholder, such as `--limit <1-100>`, says the range.

## Experiments

- Each experiment is a setting under `experimental`, off by default. fx has none today.
- Users change it like any setting: `fx config set experimental.<name> true`, `fx ask --config experimental.<name>=true` for one run, the settings file, or an Experimental section in `/settings` (planned).
- No experiment gets its own flag or env var, so finishing or dropping it removes nothing that people type. Messages that need the experiment name the setting.
- Experiments are profile-only. A project's `.fx.json` can't turn one on.

## Stability and deprecation

- Every public control carries one label: stable, experimental, deprecated, or internal.
- During the cleanup, stable means `fx ask --json` fields, ACP behavior, and env vars documented on fx.sh. Everything else may change with a changelog entry. From 1.0, everything documented on fx.sh is stable.
- A renamed or removed stable control keeps working with a warning that names its replacement, for at least two releases and at least 30 days, whichever is later. Help and completion show only the new name.
- The warning also names the release that drops the old spelling: `old_spelling_removal` in `src/core/slash_commands/command_specs.zig`, 0.0.18 for the current set. Pick a release after the first one that ships the warning, so every user sees it at least once. The shape check fails once fx's version in `src/main.zig` reaches that release, so the old spellings come out on time.

## One source of truth

- The command specs in `src/builtins/commands.zig` drive help, flag parsing, and `fx completion`. Each command's `OptionDoc` list is what its flag parser reads, and `src/core/cli/completion.zig` builds the bash, zsh, and fish scripts from the same lists. A command's words, such as `config set` or `login codex`, go in its spec's `subcommands`, which help prints under "Commands:". A word offers only its own `options` and `--help`, never its parent's, so declare the flags it takes on it. A flag with fixed values writes them in its placeholder (`--period <today|7d|month>`) or lists them in `values`. Never list a subcommand as an `OptionDoc`, and never add completion data anywhere else.
- The settings list, `src/core/config/settings_keys.zig`, holds each key's placement, kind, values, and description, and `fx completion` and `fx config schema` read it.
- Each option a run can set, such as the model or Fast mode, has one row in `run_options` in `scripts/cli_shape_registry.json` that names its agent-run flag, setting, `FX_*` variable, ACP config option, and libfx option. Names may differ by surface, as ACP's `mode` does for `--permission-mode`, but each is written there. The shape check fails when ACP or libfx offers an option that no row names, or when a row names something that doesn't exist. Add the row in the same change as the option.
- The launch flags live once in `launch_options`, and `fx --help` documents them in `top_level_flags`.
- CI fails when code reads an `FX_*` env var, compares a flag by hand, or parses a setting that the registries don't list.
- The fx.sh tables stay hand-written.
