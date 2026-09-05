```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Run fx

Sign in with Vercel AI Gateway:

```bash
fx login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. Inside fx, run `/provider` (alias `/setup`) to move between Gateway, Codex, and Grok: Enter on a subscription provider switches to it or starts its sign-in, and `vercel` opens further columns for the sign-in method, the API key to use, and the Vercel team. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Model discovery continues when its local version cache is unusable. Use `/logout codex` or `/logout grok` to remove that subscription session. Logging out of the active subscription switches to an already-connected provider, preferring Gateway and then the other subscription. If none is usable, fx stays signed out. Logging out of an inactive subscription keeps the active provider unchanged. Active subscription logout is unavailable while work is active or queued; choosing the provider again from `/provider` starts sign-in.

If a saved credential cannot be checked, `/login`, `/provider`, and `/setup` still open and identify the unavailable source. You can type the provider name immediately after Enter; credential checks preserve your input and keep choices unavailable until checking finishes. Provider and team preparation also keeps typing and cancellation responsive while its catalog loads. Ctrl+C cancels preparation without changing the current provider. A prompt submitted during preparation waits for the selected provider; if preparation fails, the prompt stays pending for explicit recovery. While responses are active or queued, these commands immediately explain that provider switching is unavailable. Other credentials remain usable. Fix the saved credential and reopen `/provider` to retry. Storage or connection failures do not start another sign-in, and browser authorization reports success only after the new credential is saved.

If credential storage fails when you submit a prompt, fx keeps the prompt and the selected account. Repair the saved credential, then press Enter to retry. A sign-in that cannot save its credential reports a storage failure. Resumed sessions restore their provider's credential and model catalog before the first prompt.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

Codex and Grok discover current stable client versions from upstream release metadata without requiring either CLI to be installed. fx caches release metadata for one minute. Opening `/model` or requesting ACP model options refreshes an expired subscription catalog. If a release lookup temporarily fails, fx uses the last successfully fetched version.

To use an AI Gateway API key instead:

```bash
fx setup
```

Embedding hosts that inject provider authentication at the network boundary can set `FX_AUTH_MODE=host-managed`. In this mode, fx does not read, refresh, or write local model-provider credentials and does not add authentication-owned headers to Gateway, Codex, or Grok requests. The host must authenticate those forwarded requests.

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. While fx is working, Enter steers the active turn at its next safe model boundary. The pending update shows its first two lines, with an ellipsis when more text is hidden. If a tool is running, fx waits for it to finish; press Escape to interrupt the active work and apply the update as soon as the turn settles.

Use `/resume` to choose a saved conversation. The picker shares its catalog across workspace views and reuses unchanged session summaries between launches. The first catalog build, or recovery from missing cache data, scans saved sessions automatically. Changed sessions are checked again, and closing the picker stops obsolete loading work.

Tool calls are expanded by default. Enable `Collapse tool calls` in `/settings`, or set `"collapse_tool_calls": true` in `~/.fx/settings.json`, to show one summary per tool-call group in the main transcript. Individual calls remain available in the full transcript with Ctrl+O. Follow-up activity for captured shell commands shows the original command, such as `Observed zig build`, while tool results keep the same execution handle.

Ctrl+L clears the inline display while keeping the conversation available in Ctrl+O. It preserves your draft and conversation context; `/clear` starts a fresh conversation instead.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fx session resume last
fx session resume --id <id>
```

Interactive terminal tabs show `fx v<version> | <folder>` using the running binary's version and current workspace folder name, for example `fx v0.0.7 | fx`. Renaming a session or switching models leaves the title unchanged. Resuming from another folder uses that folder's name. Exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

fx automatically summarizes a long session into a fresh context window when the active model request reaches 80% of its usable input capacity, then continues the same turn. Run `/compact` to create the same durable handoff immediately and wait for your next prompt.

Compaction handoffs remain internal context for the model. Resuming a session and opening its full transcript show the conversation and tool activity, not internal summaries or operation ledgers.

In saved sessions, oversized `read_tool_result` responses keep a complete terminal-safe backing copy even when the inline response is clipped. Compaction and later retrieval preserve that copy without masking the explicitly requested text again.

Resuming an older session upgrades its saved permissions and skips empty legacy file-change entries while keeping the conversation and tool results. If the model returns an empty compaction summary, fx retries the summary once without repeating tools. Cancellation or another failed summary leaves the previous context intact.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

With `--json`, `output` contains accumulated assistant Markdown across the request. Recovery replaces failed preview text rather than joining separate responses. If recovery pauses before a replacement is accepted, `output` keeps the latest preview. `final_output` contains only a completed final assistant response and is `""` for interrupted, failed, background, or otherwise absent final responses.

Foreground terminal commands run with an explicit finite deadline. fx uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

Invalid Shell requests return the specific argument problems before any command runs. When the intended repair is unambiguous, the error includes a `retry_with` request for the agent to submit through normal validation and permissions. Repeated equivalent corrections stop the tool loop.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow review of the exact pending action for concrete security danger. Prepared file mutations and static tools are reviewed without task text; reviewed commands, dynamic tools, and delegated actions also receive bounded trusted root-request context. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

In the interactive shell, bare `/mcp` opens an inline browser for servers, tools, resources, and prompts without adding anything to the transcript. Resource and prompt content enters the composer only after an explicit Insert action. Direct `/mcp SUBCOMMAND` forms remain available.

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Run `fx mcp add NAME COMMAND [ARGS...]` for a local server or `fx mcp add --transport http NAME URL` for Streamable HTTP without opening the interactive shell; the equivalent `/mcp add` forms remain available inside fx. A workspace may also provide Claude-compatible `.mcp.json` with a top-level `mcpServers` object. Pending project servers stay disconnected on every surface until they are approved with `/mcp trust approve <server>` or `fx mcp trust approve <server>`. Interactive fx presents the trust prompt after startup. `fx ask` reports skipped pending servers on stderr, and ACP leaves them unavailable. Repository files cannot persist approval or expose environment-expanded values before approval. `/mcp trust reject <server>` rejects one and `/mcp trust reset` clears the workspace choices. Profile entries win same-name collisions. Profile `~/.fx/mcp.json` accepts `mcpServers` as an alias for `mcp`, while writes always use `mcp` and ambiguous server-like keys produce a visible warning. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report invalid or suspicious trusted MCP profiles without starting their servers.

The `subagent` tool has four operations: `run` delegates one temporary task, `message` creates or continues a named persistent agent, `wait` observes a child, and `stop` cancels its current work. A first message creates the named child immediately; optional instructions set or replace that child's system overlay while preserving fx's trusted base prompt. Child sessions remain private to their saved parent session.

Run `fx mcp` to see the available commands. Use `fx mcp list`, `fx mcp path`, and `fx mcp remove NAME` for noninteractive profile management. `fx mcp trust approve|reject NAME`, `fx mcp trust approve-all`, and `fx mcp trust reset` manage workspace-scoped project trust. `fx mcp auth NAME` and `fx mcp logout NAME` run the existing remote credential lifecycle without opening the TUI or contacting the Gateway.

MCP servers have a 30-second startup timeout by default; set `startup_timeout_ms` on a server when its cold start needs a different bound. For direct `docker run` stdio entries, fx uses a private container ID file to remove the owned container after shutdown or startup failure. A configuration that already supplies `--cidfile` keeps ownership of its own cleanup policy.

Native MCP connections use the standard `initialize` handshake by default,
negotiating the supported 2025 and 2024 protocol versions. Servers that require
the newer `2026-07-28` discovery lifecycle can opt in with
`FX_MCP_PROTOCOL_VERSION=2026-07-28` in their configured `environment` map.
The SDK's host-owned client controls its own protocol negotiation.

MCP servers connect independently. In headless asks, a request for one server starts
that server without starting unrelated optional servers. Capability search loads
matching tool definitions automatically; explicit `mcp_select_tool` remains
available. The server validates its tool arguments. Image results reach supported
models as images and remain available in saved sessions; text-only models receive
an explicit notice.

Skills are advertised in a stable catalog sized to the selected model's context window. The default budget is approximately 2% of context, or 8,000 characters when the context size is unknown, with up to 1,024 characters per description. Explicit byte overrides take precedence. When space is limited, fx shortens descriptions before omitting skill identities; `capability_search` can find skills outside that catalog.

Explicit `$skill-name` mentions load the selected instructions before the model starts work. The `skill` tool accepts an advertised `location` and an optional relative `resource`, returning the complete document or a visible failure. Omitting `resource` or passing an empty string reads `SKILL.md`. File and tool-result limits still apply, and an explicit `skill_chunk_bytes` limit blocks a complete read that would exceed it. Existing named, offset-based calls remain supported.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

A [bounded long-turn memory benchmark](docs/long-turn-memory.md) exercises saved turns against a local model fixture.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
