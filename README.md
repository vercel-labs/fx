<p align="center">
  <img src="art/di-roman-ii.png" width="240" alt="di Roman numeral II mark">
</p>

# di

**A universal, native coding agent for the terminal. Pick a model; di finds the
credential and route.**

di is the `lee101/di` fork of Vercel Labs' fx coding-agent harness. It keeps the
small Zig runtime and adds provider-neutral model discovery, automatic route
switching, resilient fallback, and integration points for DictatorFlow.

## Why di

- **Any model, one binary.** `/model` is one searchable catalog across OpenPaths, OpenRouter, Vercel AI Gateway, ChatGPT/Codex, and Grok. Pick a row and di picks the credential and transport. No Max plan, no provider dance.
- **No subscription lock-in.** A model persisted under a Codex or Grok subscription that the subscription cannot serve (say, a DeepSeek failover) is routed through your OpenPaths or OpenRouter key at startup. Your model choice is kept; only the credential changes.
- **Never stalls on a dead model.** When the selected model is unavailable di circuit-breaks to a fallback for the turn, shows a banner, and keeps working.
- **Fast and small.** A single native Zig binary with a Unix-shell form factor rather than a TUI. Startup is instant and the runtime stays out of your way.
- **Runs forever when you want it to.** `di ask --auto-next-steps` keeps a session working across turns until you interrupt it.
- **Fixes itself.** `scripts/self-improve.sh` lets di run as a subagent on its own tree: one autonomous turn, gated by build, tests, and optional valgrind, then commit and push. `--merge-upstream` merges Vercel's fx and has di resolve the conflicts.
- **Open and embeddable.** Apache-2.0, WebAssembly and Node-API surfaces, ACP for editors, MCP, skills, subagents.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Build

```bash
git clone https://github.com/lee101/di.git
cd di
zig build -Doptimize=ReleaseSafe
./zig-out/bin/di
```

## Run di

di detects available credentials at startup. With `OPENPATHS_API_KEY` or
`OPENROUTER_API_KEY` in the environment, it selects that compatible transport
and works immediately without a setup command:

```bash
export OPENPATHS_API_KEY=...   # or OPENROUTER_API_KEY
di
```

The default OpenPaths model is `openpaths/stealth/ox-alpha`. When that model is
unavailable, di circuit-breaks to `deepseek-v4-flash-vision-exp` for the rest
of the turn and shows a recovered banner.

OpenRouter `:free` variants and the `openrouter/free` router still require an
`OPENROUTER_API_KEY`; “free” describes inference price, not anonymous API
access. Likewise, a ChatGPT/Codex subscription authorizes only the models in
its authenticated Codex catalog. To select a DeepSeek or other third-party
row, provide an OpenPaths, OpenRouter, or AI Gateway credential that advertises
that model. di switches the route automatically when the model is selected—it
does not copy one provider's bearer token to another provider.

`/model` is a unified searchable catalog. It merges models available through
OpenPaths, OpenRouter, Vercel AI Gateway, an eligible ChatGPT/Codex
subscription, and an eligible Grok subscription. Selecting a row also selects
the credential and transport that advertised it, so model choice is the normal
workflow rather than a separate provider-configuration exercise.

Sign in with Vercel AI Gateway:

```bash
di login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
di login codex
di
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
di login grok
di
```

`di login codex` and `di login grok` select that provider and a model from its
authenticated catalog. Subscription model IDs are the raw IDs returned by
each authenticated catalog. Use `/logout codex` or `/logout grok` to remove
only that provider session.

The OpenAI Codex route uses ChatGPT subscription access directly and never
sends its OAuth token to Vercel AI Gateway. The session is refreshed when
needed. On supported Codex models, `/fast` requests OpenAI's priority service
tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

To use an AI Gateway API key instead:

```bash
di setup
```

Run di from a project:

```bash
cd your_project
di
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `di sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
di session resume last
di session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the di-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, di copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `di ask` for a single request:

```bash
di ask "explain the changes in this repository"
```

### Compatibility state

This first rebranded release intentionally reads the existing `~/.fx` profile
and `FX_*` environment variables. That preserves prior sessions, skills, and
ChatGPT/Codex login state for people moving from fx. New provider keys use
their standard names: `OPENPATHS_API_KEY`, `OPENROUTER_API_KEY`, and
`AI_GATEWAY_API_KEY`.

## di infinity

di infinity is the infinite run harness: one `di ask` invocation that keeps working across turns until you interrupt it. After every completed turn, the saved session receives a generated follow-up prompt built from the latest work summary, so progress compounds instead of stopping at the first answer.

```bash
# keep executing the next logical implementation steps, forever
di ask --auto-next-steps --yolo "fix the failing tests and improve the implementation"

# finish the current plan, then brainstorm and ship improvements, forever
di ask --auto-next-idea --yolo "polish the terminal renderer"

# both: alternate between next steps and next ideas until interrupted
di ask --auto-next-steps --auto-next-idea --yolo "harden the gateway client"
```

How the cycle runs:

- `--auto-next-steps`: after each turn, breaks the overall goal into concrete next steps and executes them in order, running relevant tests along the way.
- `--auto-next-idea`: after the current plan is done, shifts into ideation mode, brainstorms at least three concrete improvements, picks the highest-impact one, and starts executing immediately.
- Together they form an unbounded loop; every third single-flag turn also re-reviews recent work against the original objective before acting.
- Failed turns retry automatically with exponential backoff (1s doubling to 16s), resuming the same saved session. Non-retryable failures exit nonzero.
- Stop anytime with Ctrl+C. Sessions are always saved, so `di ask --resume last` picks the harness back up later.

Autonomous mode requires session saving and cannot be combined with `--no-save`. Pair it with `--json` to get one parseable result object per turn on stdout.

## di improves di

di can act as a subagent on its own repository. Every iteration starts from a
clean tree, runs one autonomous `di ask` turn, then gates the result with a
ReleaseSafe build and the full test suite before committing and pushing.

```bash
export OPENPATHS_API_KEY=...
scripts/self-improve.sh                          # one pass, default model muse-spark-1.3-contributor
scripts/self-improve.sh -n 5 --valgrind          # five passes, valgrind gate too
scripts/self-improve.sh -m deepseek/deepseek-v4-flash-vision-exp -- "make /model list every catalog"
scripts/self-improve.sh --merge-upstream         # merge vercel-labs/fx main; di resolves conflicts
```

Iterations that fail to build or test are reverted, so the branch only ever
gains passing commits. `--no-push` keeps commits local; `--remote` and
`--upstream` select the git remotes.

## Valgrind

```bash
scripts/valgrind.sh                       # offline CLI surface under memcheck
scripts/valgrind.sh --ask "say hi"        # plus one live ask turn
scripts/valgrind.sh --tests model_fallback   # unit tests matching a filter under memcheck
```

The script builds a Debug binary with symbols, reports the memcheck error
summary per command, and exits nonzero on definite leaks or invalid accesses.
`zig build test -Dtest-filter=NAME` runs a subset of tests without valgrind.

di starts in `auto` permission mode. Routine understood development actions run directly; unresolved sensitive actions receive one bounded automatic review. A blocked action may return an exact approval request that the agent can send to di's real permission screen. Ordinary question text never grants permission. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow the existing Y/N approval prompt when stdin is a TTY. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed di

di builds as a native binary or WebAssembly. Applications embedding di can provide network transport, session storage, configuration, permission handling, and terminal I/O. The experimental JavaScript SDK keeps its existing `fx-*` artifact names for upstream compatibility.

| Surface | Use |
| --- | --- |
| `di acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend di

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `di status` and `di doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Until the fork-specific docs are split out, read the [upstream fx documentation](https://fx.sh/docs) for inherited features.

## Build from source

Building di requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/lee101/di.git
cd di
zig build -Doptimize=ReleaseSafe
./zig-out/bin/di
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
