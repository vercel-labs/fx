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

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. While fx is working, you can submit a multiline update with Enter; it steers the active turn at its next safe model boundary. When no tool is running, your message appears in the transcript immediately. Updates waiting for a running tool show their first two lines with a dotted rail and an ellipsis when more text is hidden. While an update waits on a tool, pressing Up from an empty composer pulls the newest waiting update back for editing and removes it from the queue. Press Escape to interrupt the active work and apply the update as soon as the turn settles.

Type `@` to find workspace files. Use `@~`, `@.`, or `@..` to browse your home, current workspace, or parent directory without typing a trailing slash. Names after the last slash use fuzzy matching within that directory: both `@~/ktop` and `@~/dsktp` can match `Desktop`. Once the list appears, Tab or Enter inserts the selected path; selecting a directory continues browsing inside it. Completion keeps the selected path stable across refreshes. If that selection becomes unavailable, navigate to choose again before inserting a path. If the directory is unavailable, Tab retries and Escape dismisses the picker without changing your draft. Tab or Enter before a list is presented does not select an unseen result or queue a later submission.

Selected filenames use quoting and escaping when needed for spaces, quotes, backslashes or special punctuation. For example, `@"./photo.png,"` refers to a filename ending in a comma, while manually typed or recalled `@./photo.png,` retains the image-plus-punctuation meaning. Quote or reselect an older ambiguous path before submitting it. Dollar signs inside an `@` path do not invoke skills.

Use `/resume` to choose a saved conversation. The picker shares its catalog across workspace views and reuses unchanged session summaries between launches. The first catalog build, or recovery from missing cache data, scans saved sessions automatically. Changed sessions are checked again, and closing the picker stops obsolete loading work.

Tool calls are expanded by default. Enable `Collapse tool calls` in `/settings`, or set `"collapse_tool_calls": true` in `~/.fx/settings.json`, to show one summary per tool-call group in the main transcript. Individual calls remain available in the full transcript with Ctrl+O. Follow-up activity for captured shell commands shows the original command, such as `Observed zig build`, while tool results keep the same execution handle.

When a tool targets a directory with additional project instructions, fx shows `Reading project instructions before continuing:` before the agent decides whether to retry. This refresh does not add a failure or “command not run” count to the tool summary.

While fx is working, Ctrl+C clears a nonempty composer without interrupting the turn. Press Ctrl+C again with an empty composer to cancel the active work.

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

`fx -c` (or `fx --continue`) resumes the remembered session for the current workspace directly by ID. Selecting a saved session or saving the first work in a new interactive session remembers it; opening an empty window, later background activity, and quitting do not change that selection. If no session is remembered, choose one with `fx -r` or `fx --resume <id>`. `fx --resume last` still selects the latest workspace session by activity. A busy or unreadable target produces an error rather than opening another conversation. The session picker loads its catalog when opened.

Latest-session selection with `fx --resume last` reuses validated summaries of unchanged older sessions instead of replaying their histories. The first scan, or a scan after those session files change, can take longer. Opening the resume picker preserves these cached summaries.

Older sessions that saved Vercel connection settings can be selected through `-r`, `/resume`, or an exact ID, then continued with `-c`. Migration preserves their model settings and keeps unfinished responses as interrupted history, without replaying old requests or restoring saved credential references.

If a saved conversation is damaged, run `fx session recover <id>` to copy its validated prefix into a new session. Recovery preserves checkpoint boundaries and referenced result files, leaves the original unchanged, and prints the new session ID. Records after the damaged boundary are not included, and recovery does not rerun commands. If only accounting is corrupt, recovery keeps the conversation and marks historical usage as incomplete in the copy; the original accounting file remains unchanged. Healthy conversations can be resumed without recovery. Paused requests retain their captured images across errors and restarts. Continuing uses those saved images even if the original files move or change; missing or corrupted saved images produce a recovery error.

A saved session has one writer until it closes. Suspending it with Ctrl+Z keeps its lock, so another process trying to resume the same session gets `SessionBusy`. Foregrounding preserves the current conversation and draft without reloading them.

Recovery only reports that no repair is needed after confirming the saved session can be loaded. If a final session save fails during interactive shutdown, fx reports the failure and exits with a nonzero status after cleanup, without a successful resume hint or automatic upgrade relaunch.

New sessions appear in discovery only after their initial files are ready. Incomplete creation folders left by older builds remain available for diagnosis and are not deleted. Remembered continuation does not scan these folders.

Interactive terminal tabs show `fx v<version> | <folder>` using the running binary's version and current workspace folder name, for example `fx v0.0.7 | fx`. Renaming a session or switching models leaves the title unchanged. Resuming from another folder uses that folder's name. Exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. It includes the last 256 significant renderer events collected in memory without enabling `FX_TRACE`: source rewrites, viewport/history movement, scroll commits, redraws, and resets. Run it soon after a rendering problem, before quitting or changing sessions. These events describe fx's internal rendering state, not a readback of the terminal's scrollback. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

fx automatically summarizes a long session into a fresh context window when the active model request reaches 80% of its usable input capacity, then continues the same turn. Run `/compact` to create the same durable handoff immediately and wait for your next prompt. Manual compaction refreshes the selected login when needed; Ctrl+C cancels preparation. If authentication fails, the chat stays open and unchanged so you can reconnect and retry `/compact`.

Context estimates adjust to observed provider usage, including when a local estimate is too high. Compaction budgets the recent reasoning history it keeps and can retain fewer complete exchanges when needed to leave room for the summary.

While compaction runs, the activity row shows `Compacting` with elapsed time instead of the ordinary turn label and token counts. Manual `/compact` returns to an idle composer without sending a prompt; automatic compaction continues the current turn. Cancellation and failure feedback stays in the status area, not the transcript.

Compaction handoffs remain internal context for the model. Resuming a session and opening its full transcript show the conversation and tool activity, not internal summaries, compaction notices, or operation ledgers. Cancelling automatic compaction records its origin so reopening does not add a cancellation marker; ordinary turn cancellations still appear.

Existing sessions load without migration. Sessions saved after cancelling automatic compaction contain new cancellation metadata; reopen them with the same or a newer fx build, since older builds may reject that metadata.

Saved conversations preserve original assistant replies and compatible provider continuation data. Display formatting does not rewrite saved text, and hook-driven continuation keeps earlier replies separate from the final response.

In saved sessions, oversized `read_tool_result` responses keep a complete terminal-safe backing copy even when the inline response is clipped. Compaction and later retrieval preserve that copy without masking the explicitly requested text again.

Resuming an older session upgrades its saved permissions and skips empty legacy file-change entries while keeping the conversation and tool results. Historical cache-token accounting no longer prevents an otherwise valid older session from resuming; incompatible usage totals are marked unavailable. Cancelled tools remain recorded as failures and do not prevent later compaction. If the model returns an empty compaction summary, fx retries the summary once without repeating tools. Cancellation or another failed summary leaves the previous context intact.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

With `--json`, `output` contains accumulated assistant Markdown across the request. Recovery replaces failed preview text rather than joining separate responses. If recovery pauses before a replacement is accepted, `output` keeps the latest preview. `final_output` contains only a completed final assistant response and is `""` for interrupted, failed, background, or otherwise absent final responses.

JSON results also include `usage.input_tokens` and `usage.output_tokens`, even with `--no-save`. These are the sums of token counts reported by main-agent completions in the turn, not the latest prompt size or session totals. A field is `null` when no completion reported that count; when only some completions report it, the sum includes only those known counts. JSON errors retain usage already observed. These fields do not include nested tool/provider usage, request counts, or dollar spend.

Foreground terminal commands run with an explicit finite deadline. fx uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

Invalid Shell requests return the specific argument problems before any command runs. When the intended repair is unambiguous, the error includes a `retry_with` request for the agent to submit through normal validation and permissions. Repeated equivalent corrections stop the tool loop.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow review of the exact pending action for concrete security danger. Prepared file mutations and static tools are reviewed without task text; reviewed commands, dynamic tools, and delegated actions also receive bounded trusted root-request context. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

Use `fx ask --full-access` or `/permissions full-access` to disable fx permission checks for trusted environments. The former `--yolo` flag and `/permissions yolo` command remain supported. `FX_PERMISSION_MODE` and profile `permission_mode` accept `full-access`; saved settings and JSON output retain `yolo` for compatibility.

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

For runnable Node.js, browser, Next.js, and Nuxt applications, see the [libfx examples](examples/README.md).

## Extend fx

In the interactive shell, bare `/mcp` opens an inline browser for servers, tools, resources, and prompts without adding anything to the transcript. Resource and prompt content enters the composer only after an explicit Insert action. Direct `/mcp SUBCOMMAND` forms remain available.

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Run `fx mcp add NAME COMMAND [ARGS...]` for a local server or `fx mcp add --transport http NAME URL` for Streamable HTTP without opening the interactive shell; the equivalent `/mcp add` forms remain available inside fx. A workspace may also provide Claude-compatible `.mcp.json` with a top-level `mcpServers` object. Pending project servers stay disconnected on every surface until they are approved with `/mcp trust approve <server>` or `fx mcp trust approve <server>`. Interactive fx presents the trust prompt after startup. `fx ask` reports skipped pending servers on stderr, and ACP leaves them unavailable. Repository files cannot persist approval or expose environment-expanded values before approval. `/mcp trust reject <server>` rejects one and `/mcp trust reset` clears the workspace choices. Profile entries win same-name collisions. Profile `~/.fx/mcp.json` accepts `mcpServers` as an alias for `mcp`, while writes always use `mcp` and ambiguous server-like keys produce a visible warning. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report invalid or suspicious trusted MCP profiles without starting their servers.

The `subagent` tool has two operations: `run` delegates one temporary task, and `message` creates or continues a named persistent agent. Calls normally wait for the child's result. In the interactive shell, plain-text steering lets the main agent respond while the child keeps working, then receive its result during the same turn. The activity row shows `Running` while the main agent waits for the child's result. Explicit cancellation and session changes retain their existing behavior. A first message creates the named child immediately; optional instructions set or replace that child's system overlay while preserving fx's trusted base prompt. Child sessions remain private to their saved parent session. Each call appears in the main chat with its agent name or one-off status and a short task preview; tool details retain the original response, which may acknowledge that the child is still running.

Failed calls include the captured failure reason and any partial result, including HTTP failures before an answer or after earlier tool calls. A file lookup error fails that tool call without ending the child turn, including when a target disappears during approval. Earlier tool effects are not rolled back or automatically retried. Once a persistent child's cancellation has settled, later messages continue that child without restarting the parent. Existing child records remain readable, but records saved by this version cannot be reopened by older binaries that only support child registry schema 1.

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

In the interactive shell, explicitly requested skills show a named load summary before the assistant replies. Pending skill resource reads show the relative resource path once the tool arguments arrive, without exposing the internal skill location. Full failure details are available in Ctrl+O. These automatic loads are not counted as tool calls; a loaded status confirms prepared instructions, not that the model followed them.

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

## Side Questions

**`/btw <question>`** — Ask a non-interrupting side question. Runs a single model
request with no tools, no history, and no agent loop. The main conversation
remains unaffected while the answer appears inline.

**`/recap`** — Request a read-only recap from the model without
persisting into the session history or triggering compaction. Takes no argument.

Both commands require an active credential and use the current provider and
model.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
