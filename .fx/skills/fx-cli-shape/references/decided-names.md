# Decided names

Names the maintainers already settled. Reuse them; don't add another spelling. "Planned" means not built yet: design toward it, but don't tell users to run it.

## Resume

| Spelling | Opens | Status |
|---|---|---|
| `fx -c`, `fx --continue` | The session you last worked in interactively | Keep |
| `fx -r [last\|<id>]`, `fx --resume [last\|<id>]` | One flag in short and long form. With no value, the session picker, the same list as `/resume`. `last` opens the newest saved session, and an ID opens that one | Keep |
| `fx session resume [last\|<id>]` | The newest saved session (also with no value), or an exact one | Keep |
| `fx ask --resume <last\|id>` | Same, for one-shot runs | Keep |
| `/resume` | Inside a session | Keep |
| `fx --resume-last`, `fx --resume-<id>`, hidden `fx resume`, the `--id <id>` forms, `fx ask --resume-id`, `--resume --last` | Duplicates of the above | Removed. Each fails with exit 2 and names its replacement. `fx resume <id> --upgrade-relaunch` stays as the internal restart after an upgrade |

"Newest" includes sessions `fx ask` created; "where I left off" doesn't, because `fx ask` never records the remembered session.

## Permission mode

| Surface | Name |
|---|---|
| Setting | `permission_mode`: `ask`, `auto`, or `full-access` (legacy `yolo` is read, never written) |
| Flag | `--permission-mode <mode>`, with aliases `--ask`, `--auto`, `--full-access`, `--yolo` |
| Env var | `FX_PERMISSION_MODE` |
| Slash command | `/permissions [ask\|auto\|full-access\|reset]` |
| Read-only view | `fx permissions` |

## Scopes

| Word | Means |
|---|---|
| `--global` | The profile, `~/.fx/settings.json` |
| `--workspace` | This folder's entry in the profile |
| `--project` | A committed file in the repo, only for commands that write one (`fx mcp` and `.mcp.json`) |

`fx mcp --profile` still works as `--global`, and `/allowlist` still takes `user` (the profile's top level) and `local` (this folder's entry) for `global` and `workspace`; each warns and stops working in fx 0.0.17, and fx always shows the new words.

## Settings and their surfaces

| Concept | Name |
|---|---|
| Settings command | `fx config list\|get\|set\|unset`; `--global`, `--workspace` (list and get), `--show-origin` |
| Generic per-run override | `fx ask --config key=value`, with the keys `fx config set` takes |
| Sound | `sound.turn_end`, `sound.attention_required`, `sound.max` (the older `notifications.*` is still read); `/sound on\|off\|max` and `FX_SOUND` are presets for the group |
| Status line | `status_line.*` (the older `statusLine` is still read) |
| Experiments | `experimental.<name>`, for example `experimental.sessions_v2` |
| Home | `FX_HOME` (default `~/.fx`) |
| Test hooks | `FX_TEST_*` |
| Release channel | `update_channel`; `fx upgrade --channel <name>` saves it, the way a setter command does |
| Save a default model | `/model` in a session saves it to the profile. `fx config set` refuses the model keys and points there |
| User aliases | `alias.<name>` (planned) |

## Accounts

| Concept | Name |
|---|---|
| Sign in, including pasting an AI Gateway key | `fx login [vercel\|codex\|grok]` |
| Paste an AI Gateway API key | `fx login vercel --api-key`; in a session, `/login` offers sign-in or an API key. `fx setup` and `/setup` warn and are hidden from help |
| Choose the active provider | `fx provider <name>`, `/provider` |

## Other

| Concept | Name |
|---|---|
| Shell completion | `fx completion bash\|zsh\|fish` |
| Settings JSON Schema | `fx config schema [--project]`, served at `https://fx.sh/schemas/settings.json` and `https://fx.sh/schemas/fx.json` |
| MCP servers | `fx mcp` (stays the command) |
| Usage and spend | `fx usage`, `/usage` (`/cost`) |
| In-session token and turn statistics | `/stats` |
| Exit codes | 0 success, 1 failure, 2 usage error |
| Start a session with a first prompt | `fx "<prompt>"`, one quoted argument; after a resume target, `fx -c "<prompt>"` or `fx -r <id\|last> "<prompt>"` |
| Run one request and exit | `fx ask "<prompt>"`; `-p` and `--print` only point to it |
| Versioned JSON | `--json=v2` when a shape must change |
