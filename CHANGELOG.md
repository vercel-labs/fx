# fx

## 0.0.16

<!-- release:start -->

**fx uses 41% fewer tokens. The CLI is 2.8% smaller. libfx npm downloads are about 60% smaller. Edit files up to 4× larger, now up to 16 MiB.**

### Improvements

- Long agent turns use less CPU. A paired local benchmark with 1,000 tool steps used 50–59% less CPU than the previous implementation.
- `fx update` now works as an alias for `fx upgrade`, including `--channel` and `--json`.
- Tool results keep their original timestamps when a turn is rebuilt or resumed.
- The macOS arm64 CLI binary is 2.8% smaller (5.97 MiB vs 6.15 MiB), saving 180,576 bytes.
- Installing libfx downloads about 60% less than 0.0.15, including the matching native platform package. On Apple Silicon, the download drops from 19.08 MB to 7.35 MB, a 61.5% reduction.
- Across macOS and Linux builds, total libfx npm downloads are 59.8–61.5% smaller. Unpacked package contents shrink from 43.55 MB to roughly 18–19.5 MB.
- libfx installs the native addon for your platform instead of carrying every platform’s binary. By default, Node.js loads the WebAssembly backend only when native execution is unavailable.
- Across ten model families, caching scenarios used 41% fewer uncached input tokens than 0.0.15. Requests that broke the cached prompt prefix fell from 80 to 10, an 87.5% reduction.
- Uncached input tokens fell 79% on Claude Sonnet 5.5, 78% on Claude Haiku 5.5, and 76% on GPT-6.1 in that comparison. Results varied by model, with MiniMax using 3% more.
- Prompt caching on supported models now reuses shared instructions across workspaces and worktrees.
- Changing branches or permissions, reading new folder rules, and resuming a conversation keep the earlier conversation available for prompt caching.
- Named skills send their full instructions with the turn that invokes them instead of adding them to every later request.
- Browser apps can bundle only the WebAssembly module they use instead of both the agent and terminal modules.
- The libfx WebAssembly core is 12.8% smaller than in 0.0.15 (2.15 MiB vs 2.47 MiB), and the terminal is 20.2% smaller (3.39 MiB vs 4.24 MiB). These are uncompressed binary sizes.
- `edit_file` and `write_file` handle files up to 16 MiB, up from 4 MiB.
- File edits save their diffs instead of full copies of the file before and after every change. The diff remains available in Ctrl+O after resume, with an omitted-row notice if it exceeds the saved-text limit.
- `/model` finds models from abbreviated or slightly mistyped provider and model names.
- Saved sessions retain token usage from each model reply, including replies received before an interrupted turn, and continue counting after resume.
- Subagent token usage is saved in each subagent’s own session and remains separate from its parent’s total.
- `fx ask --json` includes cached-read and cache-write token counts when the provider reports them.
- Global `~/.fx/AGENTS.md` can link to an instruction file elsewhere inside your home directory.
- Slack sign-in requests the permissions needed to search private channels and direct messages you can access.

### Bug Fixes

- When repeated response failures stop a turn, fx keeps its prompt, partial reply, and completed tool calls. The next prompt can continue from that work, including after resuming the session.
- Retrying a cancelled libfx prompt with the same turn ID returns the ended turn instead of running the prompt and its tools again.
- Opening an edit in Ctrl+O no longer crashes when the file contains terminal escape sequences.
- Editing files containing invalid UTF-8 no longer prevents the session from saving or stops the turn. Invalid bytes appear as readable escapes in previews and saved diffs.
- Fixed `fx balance` startup when reading a saved credential from the system key store.
- Stopping a terminal also stops commands running in nested shells and separate job-control groups instead of leaving them running.
- MCP server failures retain their final error output, including when the server exits immediately.
- `/usage` in the browser terminal fetches usage through the host instead of showing zero because WebAssembly cannot make native network requests.
- Qwen no longer fails after its first tool call with `System message must be at the beginning`.

### Security

- File diffs display terminal control sequences as text instead of letting them alter the terminal. This also applies when opening older saved conversations.
- Commands with escaped or separated stderr-redirection descriptors require review instead of being mistaken for routine commands that can skip review.
- `fx login codex` rejects account identifiers that cannot be used in HTTP headers before saving credentials or reporting success.
- File, tool, and skill text is escaped so it remains separate from fx’s own context and permission updates.

### Breaking Changes

- libfx now requires Node.js `^20.19.0 || >=22.12.0`, including when loaded with `require()`.
- libfx 0.0.15 cannot reopen saved turns containing the new context updates. Upgrade every worker sharing their session store before starting new turns.

<!-- release:end -->

## 0.0.15

**fx now uses 70% less memory in long conversations. The model catalog updates without restarting fx. A leaner session store with 18% faster resumes and `/fork` to branch from an earlier prompt.**

### Improvements

- In a local synthetic benchmark with 96 MiB of saved images, fx used 69.5% less peak memory (116.5 MiB vs 381.8 MiB) and completed turns 3.3× faster (288 ms vs 939 ms) than 0.0.14.
- Text sessions resume about 18% faster in local comparisons with 0.0.14.
- WebAssembly also handles longer image conversations: a separate local benchmark completed 140 turns where the earlier implementation ran out of memory at turn 102.
- Durable libfx sessions no longer reread unchanged log entries. In a 40-turn benchmark, starting the next turn took 7 serial storage calls instead of 11, a 36% reduction.
- Durable libfx sessions save prompt, steering, and tool images once instead of copying them into every checkpoint. The conversation keeps its newest 4,096 images, up to 512 MiB, and replaces older images with notes.
- fx saves pasted, dropped, and attached images once per session and tells the model where to find the saved copy. Resuming or forking a conversation loads image bytes only when needed.
- fx loads prompt history faster by skipping entries from other workspaces.
- `/model` refreshes its catalog in the background, so newly released models appear without restarting fx. Cached models remain available if a refresh fails.
- For libfx engines that save their state, a turn's `result` resolves only after the final state is saved. If saving fails, the result rejects instead of reporting success.
- Session timestamps, transcript times, usage resets, and sign-in expiry dates now use your local time zone.
- When the agent reads saved output, the transcript names the command or tool that produced it. Searches show the query too.
- ACP clients show command output rather than JSON in completed shell tool calls, including after reopening a saved session.
- Missing or changed command-output files no longer prevent `fx session recover` from recovering an older conversation. It leaves the original untouched and reports which content is unavailable.
- `fx doctor` lists older sessions it cannot convert and explains what recovery can keep. `fx sessions convert` reports skipped sessions and files left in their original folders.
- `/status` opens a scrollable panel with the current session ID, whether it is saved, and the active configuration.
- `/permissions` shows configured rules, temporary approvals, and remembered session rules in a scrollable panel, including the IDs used to revoke them.
- The resume picker searches all saved conversations in scope, not just loaded pages, and shows `Load more` only when more matches exist.
- libfx agents and the MCP adapter can use more than 64 tools.
- fx can ask up to 20 questions in one batch, up from 4.
- Vercel and MCP sign-in screens show clickable links instead of long authorization addresses.
- Changing MCP configuration restarts only the affected servers. Other servers keep their connections, tool lists, running calls, and sign-ins.
- `/mcp` groups servers that need attention and shows each server's status, connection, and tools. Startup notices wait for servers to settle.
- MCP tools show progress while they run, both in the terminal and in `fx ask`.
- Tool group summaries and the status line count MCP calls separately from shell commands.
- The agent can distinguish command runs with identical output when reading their saved results, including after resuming a session.
- Large MCP text results remain available through `read_tool_result` in saved sessions instead of failing when one item exceeds 1 MiB.
- Slack renews its MCP login without requiring another sign-in every 12 hours.

### New Features

- `/fork` starts a separate session before an earlier prompt and puts that prompt back in the composer to edit or resend. The original conversation stays unchanged.
- `/effort` lets you choose reasoning effort without changing models. Open its menu or set a supported level directly with `/effort <level>`.
- When an MCP tool requires a browser action, fx asks before opening its links and waits for completion, with Retry and Cancel available.

### Bug Fixes

- When a request is too large, fx can retry with fewer older images, including after resuming an interrupted turn. Native libfx also leaves out older images to fit its request limit instead of failing with `HostStreamBackpressure`.
- Models listed as supporting vision, including Grok 4.7, now receive attached images and images returned by tools even when the catalog does not list document input support.
- Durable libfx sessions restore images from completed tool calls after a crash, not just the text.
- Cancelling a durable prompt during an image write no longer waits for the write to finish or queues the cancelled prompt.
- Images in prompts recalled from input history remain available after fx exits, even if the temporary capture has been deleted.
- libfx restores a reply saved just before a crash without asking the model to generate it again.
- Reopening a libfx turn no longer fails after the turn yielded and continued past a checkpoint.
- Resuming a compacted conversation no longer sends the model tool steps that its summary already covers.
- Reopening an interrupted session keeps the unfinished prompt and completed tool work. Tool results that the model saw in full are restored in full, rather than replaced with short previews.
- Converting an old session keeps its original folder if a file cannot be copied, including oversized command output, and tells you which files were left behind.
- A first prompt rejected because of an API-key sign-in error stays saved, so you can fix the key and resume it.
- The resume picker orders older and converted sessions together by recency.
- Fixed a crash that could occur on a later turn in an interactive session.
- Updating fx before its first prompt no longer fails while trying to resume an unsaved session.
- Codex, Grok, and custom Chat Completions streams time out after 10 minutes without a response event, so fx can attempt to recover the turn.
- fx can recover an empty reply cut short by a provider's default output limit by retrying once. If the reply still cannot produce text, fx reports the limit instead of saying `Done.`.
- A connection can use a working address even when another address is unreachable and background tasks occupy the worker pool.
- Fixed a macOS connection error or crash that could occur after another request finished.
- Custom Chat Completions turns no longer abort when the model requests an unknown tool or supplies malformed arguments. fx returns a tool error so the model can continue.
- libfx host tool calls no longer fail when their JSON input contains line breaks.
- ACP tool calls no longer remain pending when an unsupported tool is requested or a turn fails, pauses, or is cancelled.
- Pasted text no longer disappears when extra input arrives immediately afterward. fx keeps the paste and ignores that extra input instead of submitting it.
- File-approval answers no longer get lost while background transcript or status updates repaint the screen.
- Starting a new conversation clears the previous session's context-usage count, even when session saving is unavailable.
- If an interrupted reply's restart exceeds the context limit, fx compacts the conversation and retries instead of ending the turn.
- Follow-up instructions submitted while a Stop hook runs stay in the current turn instead of being left for a later turn.
- Images from earlier turns no longer block a new text message when the selected model cannot use them. fx keeps the saved images and leaves them out of that request.
- Terminal output keeps Unicode characters and following text aligned when output arrives in chunks, including after malformed text.
- Fixed a crash when a terminal application requests the cursor position after changing scroll margins.
- Forked sessions are recognized as saved before you send another prompt, and fx shows their resume command on exit.
- zsh commands containing unquoted `==` or words beginning with `=` no longer fail with command-not-found errors.
- Shell commands keep using your saved startup environment when a zsh function replaces a default alias.
- Errors from restoring the shell environment no longer appear in command output when fx falls back to loading startup files.
- Force-stopping a command no longer lets its shell start the next command while child processes are being killed.
- Unresponsive MCP servers no longer freeze calls to healthy servers. Tool searches and subagents can use available servers while others are still starting.
- MCP tools no longer fail as unselected when the agent calls a tool from an earlier turn, including after resuming a session.
- Repeated calls to HTTP MCP servers that leave response streams open no longer crash fx. Flooding servers no longer consume unbounded memory or delay other servers' timeouts.
- HTTP MCP tool calls reconnect after an idle connection drops instead of failing until fx restarts. Reconnection retries only requests that failed before they were fully sent.
- MCP login renewal reconnects when the sign-in server drops an idle connection.
- MCP sign-ins continue when a browser leaves a connection idle or you choose Log in again.
- MCP logins refreshed in one terminal are picked up by others. Temporary refresh failures keep the saved login and report that the server is retrying.
- Invalid MCP entries or unusable tokens no longer crash startup or prevent other servers from loading.
- Oversized MCP replies explain the size limit instead of reporting that the server disappeared. HTTP replies over the limit are not downloaded repeatedly.
- MCP tool lists retain their last valid contents when a refresh fails and update before the next call after a server announces changes.
- ACP clients keep the server and tool names on MCP calls after reopening a session.
- Unreadable MCP login stores are left untouched, and failures to save a login are reported.

### Security

- fx refuses to save conversations into session-storage paths that are symlinks or not directories. Old-session conversion rejects named pipes in place of session files and does not follow linked terminal-state folders.
- Recovering an older session with unreadable saved permission rules keeps the conversation, drops those rules, and warns you.
- fx and libfx check saved images against their recorded digests before using them. Changed bytes are refused instead of being sent as the original image.
- Repeated Git config includes no longer hang file suggestions or cause runaway memory use during file searches.
- Shell comments, quoted command separators, and zsh extended globs no longer let commands bypass auto mode's security review.
- In auto mode, `git fetch` receives security review when its options or repository address can start another program.
- Reloading your shell startup files no longer reuses a remembered command approval.
- Command approval screens recognize destructive commands after quoted environment values or command substitutions.
- MCP logins saved for a repository stay separate from your profile and other repositories, even when servers have the same name and address.
- Logging out of an MCP server also clears a newer login saved by another terminal. Other running terminals no longer renew and restore a login after you log out.
- Local MCP servers inherit only basic shell variables, not your full environment. Configure any additional variables the server needs explicitly.
- Remote MCP sign-in rejects token, registration, and revocation URLs that name localhost, private IPs, or cloud metadata addresses.
- Only Slack's official MCP endpoint can use fx's built-in Slack sign-in.
- MCP configuration commands refuse to edit linked files.
- Approving all project MCP servers approves only the servers shown at that time, not servers added later.
- Answers to MCP questions apply only to the question that was displayed, not a replacement question.
- MCP server names cannot inject terminal controls, and invalid characters in tokens or headers are refused instead of being sent.

### Breaking Changes

- All saved sessions now use the new session store, and older sessions convert automatically when you open them. The `--sessions-v2` flag has been removed, and `FX_SESSIONS_V2` no longer changes storage.
- `fx session migrate` and `fx ask --continue-recovery` have been removed. `fx ask --json` no longer returns the `durable` field.
- libfx engines using Codex or Grok require an explicit model from that provider. Durable agents can set the model on each session instead.
- libfx rejects empty prompts and invalid image inputs before they are queued or saved, including malformed Base64, mismatched image types, more than 8 images, or more than 6 MiB of image data.
- Earlier libfx versions cannot open sessions written with the new image references. Existing sessions from earlier versions still open and continue.
- Sign in again to authenticated HTTP MCP servers after updating. Existing logins are left untouched but are not imported.
- `fx mcp auth` is now `fx mcp login NAME`; use `fx mcp approve NAME` or `fx mcp reject NAME` instead of `trust`. The same changes apply to `/mcp`.
- `fx mcp list` replaces `fx mcp path`. The `reload` command is gone; configuration changes reload automatically.
- MCP resources and prompts are no longer supported, and the `resource` and `prompt` commands have been removed.
- Legacy SSE MCP connections are no longer supported. Use a stdio or Streamable HTTP connection instead.
- `FX_MCP_ENGINE` has been removed. The `required` and nondefault `restart_limit` settings are ignored and reported in configuration notes.

## 0.0.14

**libfx is now durable out of the box. Same API on local, Vercel and DIY. Use your ChatGPT or Grok subscription, or a custom provider, to power cloud agents with libfx. fx moves to Zig 0.17.**

### New Features

- Durable libfx sessions can continue after crashes, [redeploys](https://fx.sh/docs/lib/durability#what-a-session-stores), and function timeouts. Interrupted tools run again only when marked `idempotent: true`.
- You can run multiple named libfx agents in one app, each with its own model, instructions, and tools. Sessions stay with the agent that created them.
- [`wakeHandler()`](https://fx.sh/docs/lib/durability#several-agents) provides an HTTP handler for queued prompts and recovery, so one Vercel route serves all your libfx agents.
- Each libfx session can override its agent's model, reasoning effort, and instructions.
- libfx now supports ChatGPT and Grok subscriptions for server-side agents, with sign-in helpers included.
- libfx agents can connect to custom OpenAI-compatible endpoints, including [local model servers](https://fx.sh/docs/lib/providers#custom-providers).
- Clients can reconnect to a libfx reply stream from the last event they received, even through a different server.
- Another server process can steer or cancel a running libfx session, or resume an interrupted turn.
- Prompts sent to a busy libfx session queue behind its running turn and start when it finishes.
- Reusing a libfx `messageId` follows the original turn instead of starting it again.
- libfx now includes TypeScript types for its public APIs.
- Pass `hooks` to `createFxAgent()` or `createFxEngine()` to observe model calls, tools, approvals, subagents, and saved-session activity on native and WebAssembly backends. Content capture is opt-in, and callback failures do not interrupt or retry agent work.
- With `--sessions-v2`, opening a session saved in the previous format converts it together with its subagent sessions. The previous-format files are removed only after the converted sessions are saved.
- Use `fx --sessions-v2 sessions convert` to convert all sessions saved in the previous format at once.
- On Vercel, libfx can use deployment OIDC credentials instead of an API key.
- `createFxEngine()` adds queued follow-ups with `followUp()` and lets you withdraw pending steering with `turn.withdraw()`.
- `/usage` and `fx usage` now show your provider's usage reports instead of locally recorded usage.
- AI Gateway usage shows your spending and budget, or the selected API key's spending, with per-model totals.
- `/usage` now shows ChatGPT plan limits and activity, plus Grok allowances, credits, and pay-as-you-go spending.
- In `@` file suggestions, Enter mentions the selected folder; Tab opens it.
- ACP clients can toggle Fast mode on supported models and keep the setting when resuming.
- `fx models --json` now lists Gateway model names, reasoning levels, and Fast and Ultrafast support.
- `fx status --json` now reports the starting permission mode, available modes, and reasoning effort.
- Compatible terminals can show when fx is working, finished, or waiting for your input.
- Commands launched by fx receive `AI_AGENT=fx`, so development tools can detect the agent environment.

### Improvements

- Prompts now appear immediately after Enter, even in long conversations.
- On Vercel, libfx starts idle sessions in the request that submits the prompt instead of waiting for a queue delivery.
- libfx waits to read a reply stream until its events or result are requested.
- Native libfx reuses HTTP connections between turns without delaying streamed output.
- libfx shares token refreshes across sessions and supports `refreshLock` for multi-server apps.
- `@` suggestions reuse a saved workspace index, and file-content searches run in parallel.
- `@` suggestions rank exact file names, name prefixes, and whole-word matches above scattered letters. Searches can span a file's containing folder and its name, and highlighted letters show the match used to rank it.
- Short `@` searches and searches with many exact matches return faster. The file picker shows up to 10 rows when the terminal has room.
- Repeated file searches use less memory during long turns.
- `grep_files` now searches files larger than 200 KiB and reports when results are incomplete.
- `ctrl+o` now wraps long commands and tool details instead of cutting them off.
- `/usage` opens with cached numbers and refreshes in the background. Press `r` to refresh manually.
- Shell tracing now includes startup-step timings for diagnosing slow launches.
- Embedded browser terminals can load your workspace's `AGENTS.md` through the host adapter.
- ACP sessions start in your saved permission mode and remember changes for future CLI and ACP sessions.
- Image-heavy requests keep the newest images and omit older ones when needed, without changing saved history.
- Request-size errors trigger a retry with fewer images before compaction.

### Bug Fixes

- Long submitted prompts and steering messages no longer overwrite earlier scrollback.
- `ctrl+o` keeps your reading position when running commands change the transcript above it.
- File searches pick up newly created files and respect parent and global ignore rules.
- `grep_files` no longer hangs when it encounters a named pipe.
- An empty or relative `HOME` no longer crashes fx or puts profile files in the current folder.
- Shell commands no longer fail when a child process exits in gVisor sandboxes, including Modal.
- Switching models or providers in ACP turns off Fast or Ultrafast when the new model does not support it.
- Embedded terminals apply Fast and Ultrafast to their first request without opening the model picker.
- libfx tool failures include an error message even when the tool throws an empty error.
- libfx saves each tool result as it finishes, so recovery can reuse completed work.
- Interrupted libfx tools no longer appear to run forever after recovery. Their events report that the call may have partly run.
- libfx rejects checkpoints created by a newer version instead of attempting to restore them.
- A steer that starts a durable libfx turn is no longer applied twice or dropped when it contains images.
- Cancelling a durable libfx session no longer stops a queued prompt that starts after the cancellation. Steering already assigned to another queued prompt no longer reaches the running turn.
- Usage totals stay visible when a refresh fails or the local cache becomes unreadable.
- Gateway requests no longer fail intermittently at startup.
- libfx rejects invalid host HTTP statuses instead of crashing the process.
- Markdown rendering no longer crashes on incomplete UTF-8.

### Security

- Workspace indexing and fx's built-in read-only Git checks no longer run repository-configured programs.
- Auto mode no longer reruns a refused built-in Git check without its protections.
- Local usage data is saved with owner-only permissions.
- Vercel and local libfx storage reject writes from a worker that has lost ownership of the session.
- libfx keeps credentials out of saved conversations and adds them only to the selected service's HTTP calls.
- libfx masks keys and tokens echoed in failed provider responses.
- Grok token refresh rejects credentials belonging to a different account.
- libfx sign-in helpers reject pasted callbacks from a different sign-in.
- Custom libfx endpoints require HTTPS outside localhost.
- libfx routes queued work to the named agent on the intended store, rather than another store with the same agent name. Use a separate `world()` store for each customer whose sessions must stay separate.
- libfx ignores queue deliveries that do not refer to an input already saved by the app. A delivery cannot replace that input or its caller context and session settings; apps must still authorize session access and authenticate their queue routes.

### Breaking Changes

- macOS release binaries now require macOS 15 or later.
- Building fx from source now requires Zig 0.17.
- `createFxAgent()` now manages durable sessions. Use `createFxEngine()` for the previous single-conversation API.
- Tools passed to `createFxAgent()` must set `idempotent: true` or `false` to say whether a call can run again after a crash.
- Native libfx runs idempotent tools in parallel unless marked `writes: true`. Other tools run alone by default.
- Images sent to durable libfx sessions must be Base64-encoded. `createFxEngine()` still accepts image files and raw bytes directly.
- Disconnecting from a durable libfx turn no longer stops it. Use `session.cancel()` or an abort signal.
- In one process, libfx agents with the same name on the same store must use the same configuration. Creating a conflicting agent throws `FX_AGENT_NAME_IN_USE`; give different configurations separate names or stores.
- Durable libfx prompts and steers, including their context and session settings, must fit within 8 MiB of JSON. Larger inputs throw `FX_INPUT_TOO_LARGE` before anything is saved.
- ACP's `code` mode has been replaced by `auto`. Clients should use `auto`, `ask`, or `full-access`.
- `/cost` has been removed. Use `/usage`.
- `fx usage --period` now accepts `today`, `7d`, and `month`. The `24h` and `30d` periods have been removed.

- `fx usage --json` now returns provider reports instead of the previous local usage totals.
- ACP usage updates report context use and no longer include costs.

## 0.0.13

**fx now supports Ultrafast on supported OpenAI models and launches up to 23× faster. Shell calls are up to 8.6× faster, and exits are up to 44× faster in matched benchmarks.**

### Breaking Changes

- Terminals launched through the shell tool now stop when fx exits instead of staying alive for the next resume.
- New libfx checkpoints cannot be restored by older versions. Existing checkpoints still load.
- Invalid Base64 image input now throws directly from `prompt()` instead of failing the turn later.

### New Features

- Enable Ultrafast with `/ultrafast on` or `--ultrafast` on supported OpenAI models through AI Gateway. It uses a higher-priced inference tier.
- Subagents and ACP sessions support Ultrafast. libfx supports it through `model.ultrafast`.
- `/mcp add slack` now configures Slack, opens sign-in, and connects your account in one command.
- Set `auto_compact_percent` from 10 to 80 to choose when automatic compaction starts.
- libfx accepts raw image bytes and adds a `resizeImage` hook for preparing images before sending.
- libfx image references survive checkpoints, so your app's tools can recover originals later.
- ACP clients can steer running turns, supply session instructions and workspaces, and host MCP servers over the ACP connection.

### Improvements

- Launch benchmarks show 1.6–23× faster median first-screen rendering, depending on the terminal. Sign-in and skills finish loading afterward.
- Shell calls are up to 8.6× faster with heavy startup files, dropping from 238.8 ms to 27.9 ms. Startup files load once per fx process; `/shell reload` refreshes them.
- Exiting after a reply is up to 44× faster while a large usage history is loading, dropping from 1,003 ms to 23 ms.
- Exiting with MCP servers is 2.8× faster in the matched macOS benchmark, dropping from 20.6 ms to 7.4 ms.
- The shell overhaul removed 236–279 KB from native binaries in matched builds.
- Compaction preserves original messages and final replies where they fit, while older turns and tool results remain searchable.
- The Grok model picker now shows all supported subscription models.
- Images can reach the model at up to 8,000 pixels per side when the request contains 20 images or fewer.

### Bug Fixes

- Steering sent after a tool result now survives cancellation and resume.
- Subagents now start when the parent has more than 256 MCP tools.
- Compaction no longer incorrectly flags answers to questions as unsupported rules.
- Sessions v2 now retain assistant text around interrupted tool calls and generate titles after a crashed first turn.

### Security

- Reloading shell configuration clears remembered command approvals. Auto mode reviews routine commands that use captured aliases or functions.
- ACP sessions use profile MCP servers only when the client explicitly opts in.

## 0.0.12

**Session listing is up to 560× faster, large stores resume in under a second, and GitHub-flavored Markdown now renders better throughout the terminal.**

### Breaking Changes

- libfx now uses `LIBFX_MODEL_UNSUPPORTED_EFFORT` and `LIBFX_MODEL_UNSUPPORTED_FAST` for unsupported model settings. Callers checking the old error codes must update.

### New Features

- libfx accepts `model: { id, effort, fast }` and supports `Blob` or `File` images directly.
- Detached processes such as `tmux`, `ssh-agent`, and browser drivers now stay alive between shell calls.
- `/mcp list` now opens the interactive Servers menu.

### Improvements

- In a 14,600-session benchmark, `fx sessions` dropped from 95 seconds to 0.17 seconds and `fx --resume last` from 33 seconds to 0.5 seconds.
- `/new`, `/clear`, and `/reset` now preserve the previous conversation in terminal scrollback.
- Oversized PNGs shrink before being sent without changing the original file. fx tells you when another image cannot be sent.
- Structured replies now use GitHub-flavored Markdown. Wide tables wrap inside their cells, and long URLs stay clickable.
- Steering stays intact through compaction and session recovery.
- MCP startup errors now explain whether the server exited, timed out, or returned invalid output.

### Bug Fixes

- Prompt-too-long errors now trigger compaction and one retry.
- Numpad keys now work in the composer, including digits, operators, Enter, and navigation.
- Codex, Grok, and custom connections now start with `--model` or `FX_MODEL` even when no model is saved.
- `/model` now identifies models from custom connection settings without suggesting a Gateway sign-in.
- Clearing the terminal with `Cmd+K` or `Ctrl+L` no longer crashes conversations containing tool calls.
- tmux's session switcher and copy mode now stay open during terminal resizing.
- `fx pr --create` and `fx issue --create` now publish the final response instead of earlier progress text.
- Messages sent after interrupting a response now wait for the previous turn to close.
- Malformed tool arguments no longer break the next model request.

### Security

- Slack MCP sign-in now requests only approved fx scopes and rejects unexpected OAuth resources or scope changes.
- Symlinked skills outside fx's usual directories can now be allowed through `skill_symlink_authorities` in profile settings. Project settings cannot grant that access.

## 0.0.11

**fx now supports custom model connections and themes. Resume, file lookup and request handling are up to 100× faster, long turns use 17× less memory, and libfx adds steering, images, web search and model controls.**

### Breaking Changes

- **Automatic recovery:** `/continue` has been removed. fx now retries and continues on its own.

### New Features

- **Default model:** fx now uses Grok 4.7 as its default model. Fast mode remains opt-in.
- **Custom connections:** fx now supports named OpenAI Chat Completions connections for local servers and other gateways. Configure them in `~/.fx/settings.json`, then select one with `fx provider <name>` or `FX_PROVIDER`.
- **Provider routing:** Gateway users can set `provider_order` and `provider_strict`, or pass `--provider-order` and `--provider-strict`, to prefer or restrict which providers serve a model.
- **Interactive flags:** Interactive sessions accept `--provider`, `--model`, `--effort`, and `--fast`; `fx ask` accepts `--model`, `--effort`, and `--fast` for one run without changing saved preferences. Grok models now support Fast mode.
- **Slack bot:** fx can now install and manage your Slack workspace bot from the CLI.
- **Custom themes:** fx now loads custom TUI themes from `~/.fx/themes/<name>.json`, including VS Code themes. Set `theme` in `~/.fx/settings.json` or use `FX_THEME`.
- **Image reading:** `read_file` now attaches PNG, JPEG, GIF, and WebP files to supported vision models.
- **libfx steering:** libfx turns support `turn.steer()` for mid-turn guidance. Applied steering arrives as a `user_message` event and remains in checkpoints.
- **libfx model controls:** `createFxAgent()` now accepts image blocks plus `effort` and `fast` options. libfx now supports `web_search`.
- **libfx activity:** libfx hosts receive `transport.activity` while responses stream, and `tool_start` now includes tool input or a bounded preview.
- **libfx tool boundaries:** libfx now keeps host tools separate from fx's built-in tools, even when they share a name.

### Improvements

- **Recovery:** Transient model failures now retry until the connection recovers. Silent streams use liveness checks, and retries slow to once a minute after 15 minutes.
- **Session resume:** `/resume` opens up to 60× faster with better session caching.
- **File suggestions:** `@` file suggestions are 6–40× faster with a saved index and background scanning.
- **Gateway setup:** Gateway connection setup is up to 48× faster by warming and reusing connections across turns.
- **Usage tracking:** Usage tracking is over 100× faster on large local histories.
- **Memory use:** Long tool-heavy turns use over 17× less memory in the release benchmark.
- **Compaction:** Compaction now preserves conversation history more accurately for better continuation afterward.
- **Syntax highlighting:** Shell commands and code blocks now have better syntax highlighting across more languages.
- **MCP errors:** MCP now shows clearer startup and authentication errors, including what to do next.
- **MCP forms:** Small MCP forms with one choice and up to three options submit directly from the terminal prompt.
- **Diagnostics:** Logs in `/trace` and `ctrl+o` are cleaner and more useful for diagnosing session issues.
- **Subagents:** Subagent rows show the child's model, effort, token use, and task status. Exact and unambiguous partial model names now work in subagent overrides.
- **Faster exits:** Double `Ctrl+C` exits up to 40× faster when MCP servers are stuck, and no longer waits on upgrade downloads.
- **Command rendering:** Command rows now resize with the terminal, giving long shell commands cleaner rendering.

### Bug Fixes

- **Multiple images:** Reading multiple images in one turn no longer crashes fx, and images returned by tools now reach vision models through Gateway.
- **Image accounting:** Tool images no longer count as text during request estimation. Automatic compaction now uses the real image cost.
- **Session titles:** Resuming an untitled session now generates a title from its first committed prompt instead of preserving `Untitled session`.
- **Session saving:** A completed turn that fails to save no longer exits fx. The response stays in memory and the save error remains visible.
- **Workspace search:** `grep_files` and `glob_files` no longer end an otherwise completed turn when searching from the workspace root.
- **Full-screen views:** Typing while `ctrl+o` or another full-screen view is open no longer disturbs the main conversation. Queued prompt previews also stay clear of active transcript rows.
- **Tool recovery:** Tool failures now name the unresolved path and tell the model when to reread a file or choose another approach instead of retrying blindly.
- **Cancelled recovery:** Cancelling response recovery no longer revives the stopped turn on resume. After restarting, the model is also told that old background shell sessions no longer exist.
- **MCP capabilities:** MCP resources and prompts no longer fail the whole tool call when a server never advertised that capability.
- **MCP authentication:** Rejected or expired MCP credentials now show `needs_auth` and the right re-authentication command instead of appearing authenticated.
- **Terminal resume:** Resumed terminal rows show the recorded launch command, including after moving the workspace, instead of raw session IDs or fixed-width text.
- **Transcript retention:** Transcript retention no longer overwrites finalized conversation rows or loses pending rows during resize and full-transcript viewing.
- **Fast mode fallback:** When the model catalog is unavailable, fx reports that the requested Fast mode could not be enabled and continues normally.
- **Steering recovery:** Steering and response recovery no longer lose buffered assistant output or completed turn summaries.

### Security

- **Custom connection credentials:** Custom connections read credentials only from their named environment variable, and committed project configuration cannot define model endpoints. Saved sessions refuse to resume against a changed endpoint or authentication identity.
- **Review model:** Set `review_model` or `FX_REVIEW_MODEL` to choose the model used for auto-mode safety reviews. Review transport failures and malformed replies retry once; cautions never retry for approval, and an unresolved action stays blocked.
- **Safe tool errors:** Tool failure details now redact secrets and escape terminal control sequences before rendering.

## 0.0.10

**fx now completes turns up to 1.6× faster and starts model requests up to 2.5× faster.**

### Improvements

- Speed gains vary with session length and usage. Longer sessions improve the most.
- Shell failures now give the model clearer recovery guidance.
- `/trace` now provides better diagnostics for session-title issues.
- System notices have a cleaner visual treatment.

### Bug Fixes

- Resume recovery now restores shell activity more reliably.
- Scrollback retention is more reliable when resuming long conversations.
- Resolved questions and answers now render cleanly across terminal widths.

### Security

- MCP errors now have stronger secret protection.

## 0.0.9

**fx can now use a frontier model for steering, then delegate to cheaper models to implement. Subagents keep running while you steer, can have different models and reasoning levels, and take feedback mid-task. We're accomplishing this without any new commands or concepts, just chat with fx.**

### Breaking Changes

- For simplicity, `!` in the composer is just prompt text now. It no longer starts a terminal session. Commands go through the agent and the usual approval flow.

### New Features

- Subagents can use their own model and reasoning effort. Use GPT-6, Astra, or Fable 5.1 to steer, then delegate implementation to Kimi K3.
- You can send feedback to a running named subagent without interrupting its current tool. The final result still comes back to the parent conversation.
- New conversations get a short title from the first prompt. Turn generated session titles off in `/settings`.
- Press `ctrl+p` while writing to open the model picker. Your draft and attached images stay where they are.
- ACP clients can set reasoning effort on supported models. They can also replay earlier tool calls as structured events.
- New runnable `libfx` examples for [Node.js](https://fx-demo-node-chat.vercel.app/), [browsers](https://fx-demo-browser-agent.vercel.app/), [Next.js](https://fx-demo-nextjs-agent.vercel.app/), and [Nuxt](https://fx-demo-nuxt-agent.vercel.app/).

### Improvements

- `fx -c` and `fx --continue` now resume the workspace’s remembered conversation without a full session scan.
- Compaction now shows in the activity row. If you send a message while it's running, it waits, then runs with the compacted context.
- Assistant Markdown now renders nested emphasis, links, code spans, lists, fenced code blocks, and entities the way GitHub does.
- `@~`, `@.`, and `@..` open the home directory, workspace, and parent directory. No trailing slash needed. File suggestions also stay put while you browse and refine them.
- Escape needs a second press within one second to interrupt active work. ctrl+c clears a non-empty composer first; with an empty composer, it interrupts active work, then exits fx on the next press.

### Bug Fixes

- Running subagents keep going if a file lookup fails. Follow-up messages also don't leave named subagents stuck.
- AI Gateway now applies the reasoning effort you selected on chat requests. Prompts with images no longer fail on the v4 endpoint.
- Long replies no longer shuffle transcript rows or overwrite the last character on a full-width terminal line.
- MCP OAuth now works with servers that support PKCE but leave `none` out of their metadata, including Slack MCP.

### Security

- Auto mode now checks which terminal session it's sending input to, including after a resume.
- Auto mode no longer reuses an earlier safety-review decision when judging a later action.
- Auto mode no longer raises false cautions when you use a credential with the service it's for, or with a local test process.

## 0.0.8

**fx is smaller, simpler, and faster. libfx initialization in Node / browser is over 40× faster; fx binary is 7.49% smaller. fx uses a smaller three-action shell, context compaction is optimized per model, and Enter steers active turns instead of queuing follow-ups.**

### Breaking Changes

- fx now uses a smaller shell tool with 75% fewer actions (3 vs 12), replacing the old terminal tool.
- Enter now steers active turns instead of queuing follow-ups, and ctrl+enter does the same.
- The subagent interface now has 67% fewer commands (2 vs 6), with direct delegation replacing the ctrl+x manager.
- The memory tool has been removed without deleting existing saved memories.
- createFxAgent() now exposes prompt, checkpoint, and close instead of the old session, model, and config APIs.
- createFxAgent() now takes apiKey and an optional model directly; Agent configuration through env is no longer accepted.
- capability_search replaces the retired skill_search and mcp_search_tools.
- The public --record startup flag has been removed.

### New Features

- Compaction now keeps recent tool exchanges intact, preserves the full transcript, and continues the same turn in a fresh context window.
- fx can run one-off tasks or continue named agents directly from the conversation.
- The shell now supports up to 64 live executions.
- /mcp now opens a terminal browser for servers, tools, resources, prompts, authentication, and project trust.
- MCP tool images now reach supported models and remain available after resume.
- JavaScript hosts can now add their own tools, MCP clients, and skills across Node, Bun, and browsers.
- The libfx package has no runtime dependencies; host-supplied tools and MCP clients may have their own.
- ACP image prompts now support up to 3.75 MiB per image.
- /provider, /setup, and /login now open the same column picker for providers, sign-in methods, API keys, and Vercel teams.
- libfx now provides listModels() for explicit model discovery without creating an Agent.
- Embedding hosts can use FX_AUTH_MODE=host-managed without reading or writing local provider credentials.
- --full-access and /permissions full-access replace YOLO in the UI and commands; the old aliases still work.
- fx ask --json now reports input and output tokens.

- libfx now supports both ESM imports and CommonJS `require()` in Node.
- Native libfx Agents now run in Next.js 15 and 16 server routes without extra bundler configuration.
- `getBackendInfo()` now reports available libfx backends and loading errors without creating an Agent.
- `fx session recover <id>` can recover damaged conversations into a new session while leaving the original intact.

### Improvements

- Native Agent initialization is tens of times faster, dropping from hundreds of milliseconds to single digits.
- Native streaming no longer waits on the polling bridge.
- Synthetic native host-tool round trips measured 3.10 ms in Node and 1.56 ms in Bun at p95.
- In the current benchmark, all 22 measured TUI interactions complete within 15 ms at p95 across 50 samples each.
- CLI startup now takes about 0.5 ms before terminal initialization.
- ctrl+o now shows timestamps, complete tool details, errors, and per-turn token usage in one view.
- Skill and MCP searches now reject weak matches while preserving exact names and technical terms.
- AI Gateway now uses Exa by default for web searches, with Parallel as the fallback.
- AI Gateway caching is now enabled automatically for agent conversations.
- New sessions use shorter 12-character IDs while existing IDs remain resumable.
- File and model pickers remain available while fx is working, and model changes apply to the next turn.
- Steering messages now appear in chat immediately and wait only while a tool is running.
- Codex and Grok model lists refresh in open terminal and ACP sessions without requiring their CLIs.
- Stable Wasm sources compile once per JavaScript realm while each Agent keeps separate state and memory.
- MCP servers now connect independently, and optional servers start only when needed.
- Subagent tasks and replies now appear in chat, with failures and partial results preserved.
- The /resume picker now reuses cached session summaries instead of rescanning every time.
- Terminal tabs now show the fx version and workspace folder.
- libfx now pauses large streams when hosts fall behind instead of losing output.
- ctrl+c now clears the composer first and cancels active work only when the composer is empty.

- Long saved conversations now resume faster, including repeated `fx -c` continuation.
- Scoped project instructions now refresh before continued turns, including rules changed since the last tool call.

### Bug Fixes

- Models with native image support no longer receive the redundant vision tool.
- Terminal fx ask now loads approved MCP servers before the first model request.
- The footer now shows Fast mode only when it matches the active model.
- fx now keeps replies in the language of the latest user request.
- AI Gateway requests can run for up to 30 minutes, and timed-out streams pause instead of retrying automatically.
- Partial command output and known process status are preserved when output reading fails.
- Forced shell termination now stops waiting after 6 seconds and reports when termination cannot be confirmed.
- Tools that fail before execution now show why they did not run.
- Cancelling an ACP prompt now stops the work instead of leaving it running.
- Gateway, Codex, and Grok no longer fall back to another credential source when the selected one is unavailable.
- New sessions remain saved when another fx process is updating session history.
- Older sessions now upgrade without losing conversation history or tool output.
- Explicitly requested skills now load completely and show their status before the reply begins.
- Cancellation feedback now appears immediately after esc, while completed tool results remain intact.
- Invalid shell requests now explain the argument problem and suggest a correction only when the repair is unambiguous.
- Recovered responses no longer join text from separate attempts or repeat completed tool calls.
- Provider selection remains responsive while credentials and models load, and sign-in can resume after logout, cancellation, or credential failures.
- Large session reads no longer block concurrent saves.
- Cancelled libfx prompts stop waiting on host tools and cannot affect later turns.
- Native streaming preserves Unicode split across output chunks and continues after delayed cleanup.
- Closed libfx Agents now release native threads, notification descriptors, and Wasm instances.
- Pending MCP authentication no longer blocks a newer reload.
- ctrl+o history now survives ctrl+l, terminal resizing, reopening, compaction, and resume without missing or duplicate entries.
- Provider streams and parallel tool calls no longer lose or duplicate text, reasoning, and tool results.
- Prompt images now survive tool calls and resume without falsely exhausting context.

- Image recovery now uses saved attachments after restart, even if the original files move or change.
- Missing or corrupt saved images now report an error without discarding the pending request.
- Manual compaction now refreshes the selected login and keeps the conversation unchanged if sign-in fails.
- Cancelled tools no longer prevent manual or automatic compaction, including after resume.
- Long reasoning sessions no longer hit false context limits or leave too little room for compaction.
- `fx -c` now skips incomplete sessions and reports errors for the selected session instead of opening an older conversation.
- Missing or incompatible usage data no longer blocks valid conversations from resuming; unavailable historical totals are marked explicitly.
- Session recovery now handles corrupt usage data and reports unreadable saved state instead of claiming no repair is needed.
- Suspending fx with `Ctrl+Z` now keeps the session locked, preventing another process from changing it before foregrounding.
- Failed session writes preserve existing history and pause work when saving cannot be confirmed.
- Completed turns remain saved after rendering failures, and save failures on exit now return an error.
- Multiline steering around tool completion no longer crashes fx or loses the submitted message.
- Web searches no longer fail when the model restarts its streamed reply after a tool call.
- Failed or interrupted subagents no longer appear as successful empty replies.
- libfx checkpoints now preserve reasoning and provider tool results, including responses without visible text.
- Promised Wasm assets now load correctly in Node, and CommonJS deployments retain their native addon.
- Embedded terminals now clean up after startup failures and cancel pending requests when output fails.
- Credential recovery guidance now names the selected source and explains how to repair it.

### Security

- Auto mode now reviews the exact pending action and no longer warns on benign work because command text appeared in tool output.
- Symbolic credential references remain reviewable, while literal values stay masked and blocked.
- ACP requests must target the active session, and managed child sessions stay private to their parent.
- MCP resources and prompts enter the composer only after an explicit Insert action.
- OAuth discovery accepts a single trailing-slash difference while keeping authorization responses exact.
- Importing libfx does not connect MCP, scan skills, spawn processes, or read files.
- Command output is escaped before reaching the model or terminal.
- Host-owned instructions are the complete libfx system context; libfx adds no hidden coding prompt.
- Browser sign-in reports success only after the credential is saved, and unusable refresh credentials are retired.
- libfx sends Agent network requests only through the host-provided fetch function.
- Inherited fx tracing settings no longer create unexpected libfx output or trace files.

- Resuming legacy sessions no longer restores old credential references or sends unfinished requests under unverified credentials.
- Internal subagent sessions stay out of latest-session selection.
- Conflicting provider tool records are rejected before execution.

### Ecosystem highlights

- [Cal.com](https://cal.com/docs/mcp-server)
- [Clerk](https://clerk.com/docs/guides/ai/mcp/clerk-mcp-server#connecting-fx-to-clerks-mcp-server)
- [Kernel](https://www.kernel.sh/docs/reference/mcp-server/clients/fx)
- [Knock](https://docs.knock.app/ai/mcp-server#fx)
- [MongoDB](https://www.mongodb.com/docs/mcp-server/get-started/?ai-client=fx)
- [Neon](https://neon.com/docs/ai/connect-mcp-clients-to-neon)
- [Plain](https://www.plain.com/docs/agents/mcp-server#fx)
- [Prisma](https://www.prisma.io/docs/ai/tools/mcp-server#fx)
- [Sentry](https://mcp.sentry.dev/?ide=fx)
- [Stagehand](https://docs.stagehand.dev/v4/integrations/fx)
- [Supabase](https://supabase.com/docs/guides/ai-tools/mcp)
- [Upstash](https://upstash.com/docs/agent-resources/clients#fx)

## 0.0.7

**MCP is safer, easier to manage and more compatible; project servers require explicit trust, `fx mcp` is now a top-level command, `Enter` steers active turns and fx uses eight fewer tools to preserve context.**

### Breaking Changes

- **Model selection**: `/model` now handles the full selection flow, from quick choices to the complete catalog.
- **Fewer filesystem tools**: fx now advertises eight fewer tools for better accuracy and more context, with `terminal` handling core filesystem operations.

### New Features

- **Active-turn steering**: While fx is working, `Enter` steers the active turn at the next safe model boundary. If a tool is running, fx waits for it to finish; `Escape` interrupts the active work and applies the update as soon as the turn settles.
- **Collapsed tool calls**: `/settings` now includes `Collapse tool calls`, which shows one summary per tool-call group in the main transcript. Individual calls remain available in the full transcript with `Ctrl+O`.
- **Project MCP configuration**: Workspaces can now define project MCP servers in `.mcp.json` alongside profile servers.
- **Top-level MCP management**: `fx mcp` is now a top-level command with `add`, `list`, `path`, `remove`, `auth`, `logout`, and `trust`.
- **Capability discovery**: fx can now search installed skills and configured MCP tools together from a natural-language request, then load or select the exact match before use.
- **Passive MCP listings**: `fx mcp list` reports configuration and saved authentication without connecting to servers. Add `--connect` for live discovery and health checks.
- **Structured final output**: In `fx ask --json`, `output` contains all assistant Markdown and `final_output` contains only a completed final response. Interrupted, failed, and background turns return an empty `final_output`.
- **ACP session discovery**: ACP `session/list` now lists sessions across workspaces when `cwd` is omitted, includes saved titles, and paginates results in groups of 100.

### Improvements

- **Transcript visibility**: Menus now open inline, so the transcript stays visible while you browse.
- **Focused menus**: Menus now use category, scope, and provider filters to show more relevant options.
- **Usage visibility**: Usage data now loads without blocking the interface and tracks token and request totals without double counting.
- **MCP diagnostics**: `fx status` and `fx doctor` now report configured servers and project configuration errors without starting servers or loading credentials.
- **MCP profile compatibility**: `~/.fx/mcp.json` now accepts `mcpServers` as an alias for `mcp`, while every write uses `mcp`.
- **Live turn feedback**: Submitted prompts, turn progress, elapsed time, and token usage now stay visible throughout the turn.
- **Smoother response streaming**: Assistant output now appears in complete blocks instead of character by character.
- **Code blocks**: Code blocks now use solid horizontal rules instead of side rails, keeping language labels and copied source clean.
- **Subscription sign-in**: Sign-in stays clear and usable on compact terminals, while manual code entry appears only when needed.
- **Automatic reviews**: Automatic permission reviews now allow more time before reporting that review is unavailable.
- **System prompt overrides**: Command help now documents temporary system-prompt replacement while keeping tool, skill, project, and runtime context.

### Bug Fixes

- **Transcript stability**: Streaming responses no longer move scrollback or rewrite completed output.
- **Environment compatibility**: Interactive input now works correctly on WSL, and browser-hosted fx stops unsupported network work instead of retrying it.
- **Retry recovery**: Automatic retries now show progress, clear stale state, and stop silent Gateway attempts.
- **Terminal cleanup**: Timed-out and cancelled commands stop cleanly, keep accurate outcomes after resume, and avoid unsafe retries when completion cannot be confirmed.
- **Terminal recovery**: Sessions recover from host shutdown, accept input without a helper restart, and return control when the turn ends.
- **Saved tool output**: Saved results remain readable when a generated handle omits its file suffix.
- **MCP reliability**: MCP servers now start, stop, reconnect, and report errors more consistently across modern and legacy implementations.
- **Subagents and approvals**: Subagents keep their reasoning settings, and visible child approvals continue receiving input while the view refreshes.
- **ACP responses**: ACP clients receive clean Markdown, and resumed responses no longer repeat text already delivered.
- **Undo safety**: `/undo` now keeps the original file intact when a restore cannot be completed and refuses attempts redirected through a new symlink.

### Security

- **Signed macOS releases**: Stable macOS releases are now signed and notarized before packaging.
- **Project MCP protections**: Project servers and environment values remain inactive until approval, tool calls are checked again before reaching a server, and ambiguous configuration writes are refused.
- **MCP credentials**: Valid credentials remain usable across non-expiring tokens and macOS accounts without a default Keychain, while malformed or rejected credentials are reported correctly.

### Ecosystem highlights

- [Notion](https://developers.notion.com/guides/mcp/overview)
- [Exa](https://exa.ai/mcp)
- [Hugging Face](https://huggingface.co/docs/hub/agents-mcp)

## 0.0.6

**New Gateway sessions use Kimi K3 with Fast mode, foreground commands require timeouts, auto mode reviews exact pending actions, and the macOS arm64 binary is 0.3% smaller (6.12 MiB vs 6.13 MiB).**

### Breaking Changes

- **Terminal presentation**: `/appearance`, `/input`, and `/maxxing` have been removed along with their saved settings. fx now uses the same input and transcript layout everywhere.
- **Foreground command timeouts**: `terminal.exec` calls now require `timeout_ms` between 1 millisecond and 10 minutes. Use `terminal.start` for services, watchers, GUI apps, and other long-running work.

### New Features

- **Remote MCP servers**: `/mcp add --transport http <name> <url>` now saves or replaces a remote Streamable HTTP server and reloads MCP immediately. The existing local stdio form is unchanged.
- **Retained command output**: Captured command output can now be read later with `read_tool_result`, including after a saved session resumes. With `--no-save`, output remains available until fx exits.

### Improvements

- **Auto mode review prompts**: Auto mode now uses fewer tokens when reviewing unresolved actions.
- **Native binary size**: The macOS arm64 binary is 0.3% smaller (6.12 MiB vs 6.13 MiB).
- **Gateway defaults**: New Gateway sessions now use Kimi K3 with Fast mode enabled by default.
- **Setup hub**: `/setup` now groups sign-in methods under Connections and shows the current provider, Vercel team, and credential source. Child screens return to the setup hub, and active sign-in controls remain visible in compact terminals.
- **Provider model preferences**: Gateway, Codex, and Grok now keep separate saved model selections, so switching providers no longer replaces another provider's preferred model.
- **Subscription session longevity**: Codex and Grok sessions remain usable beyond 64 consecutive requests.
- **Usage tracking**: Rejected completions no longer appear in usage tracking, and duplicate completion callbacks are recorded once.
- **MCP discovery**: MCP searches still find the selected tool when a request includes surrounding context, and another server's authentication failure no longer replaces an empty search result.
- **MCP authentication**: MCP authentication stays responsive while configuration reloads or logout is in progress, and pending authentication stops when MCP reloads or fx exits.
- **Linked skill errors**: Linked skill errors now distinguish an unavailable linked directory from an unreadable `SKILL.md` and explain whether to repair, remove, or authorize the link.
- **Live permission modes**: `Shift+Tab` permission-mode changes now apply to later tool calls in the current turn. Actions already in progress keep the mode under which they were admitted.
- **Tool action summaries**: Denied and deferred tool rows now show the actual command or target, and those details and denial labels survive session resume.

### Bug Fixes

- **Terminal resize**: Terminal resizing no longer leaves empty scrollback behind.
- **Subscription sign-in**: Codex and Grok sign-ins now survive unrelated, stalled, reset, or stale browser connections. Grok authorization codes can also be pasted when the browser cannot return to fx.
- **OAuth callback pages**: OAuth callbacks now show a completion or failure page after returning from the browser.
- **Nested rebuilds**: Interactive terminal helpers continue working after a nested rebuild replaces the fx binary on disk.
- **Terminal recovery**: fx recovery no longer pauses commands already running in tmux.
- **Terminal cancellation**: Terminal cancellation no longer reports failure when the command exits during cancellation.
- **MCP resource compatibility**: MCP resources and prompts no longer fail on servers that require their configured name.
- **MCP credential recovery**: MCP credentials with no advertised scopes remain usable after restart. Malformed stored entries no longer prevent valid servers from loading and are removed on the next successful credential write.
- **MCP stdio environments**: Configured MCP stdio environment variables now override inherited values without discarding the rest of the child environment.
- **Captured command failures**: Captured command output remains readable after timeout or cancellation. Output-capture failures now fail the tool call instead of returning an incomplete result.
- **Resumed review labels**: The `Safety caution` and `Review unavailable` labels now survive session resume.

### Security

- **Exact-action reviews**: Auto mode reviews each unresolved action against the current request and relevant results from the current turn. A clear review applies only to that exact unchanged action and is checked again before execution.
- **Blocked cautions**: Cautioned or unavailable actions remain blocked without opening a permission prompt or ending the turn.
- **Untrusted tool output**: Actions copied from untrusted tool output remain blocked unless the user's request independently authorizes them.
- **Current-branch pushes**: Explicit pushes to the current branch use the branch reported by the local Git checkout rather than repository text.
- **Provider recovery authority**: After restart, fx continues unfinished Codex or Grok work only for the account that started it. If that account cannot be verified, fx preserves completed work and sends nothing.
- **Sensitive command output**: Command output flagged as sensitive is not saved with the session, including secrets split across output chunks or oversized lines.
- **OAuth callback validation**: OAuth authorization denials and successes apply only when the callback state matches the active sign-in attempt, and Grok browser callbacks accept only the expected xAI origin.
- **MCP issuer validation**: MCP sign-in stops before exchanging a token or saving credentials when the authorization response comes from a different issuer than the server advertised.

## 0.0.5

### Breaking Changes

- **Host command execution:** Run approved captured, background, and monitor commands as ordinary host subprocesses, and retire sandbox configuration, status fields, and commands
- **Interactive provider switching:** Move provider selection to `/setup` and remove the `/provider` slash command while keeping the top-level `fx provider` command

### New Features

- **Codex subscriptions:** Sign in with an eligible subscription through `fx login codex`, then use authenticated Codex models for interactive sessions, `fx ask`, native ACP, images, subagents, and automatic reviews
- **Grok subscriptions:** Sign in with an eligible Grok subscription through `fx login grok`, then use authenticated xAI models, effort levels, images, local tools, persistent sessions, and automatic reviews
- **Workspace status line:** Opt in to the active workspace path and Git branch through `/settings`, `/statusline workspace`, or `statusLine.workspace`
- **fx-native workspace skills:** Discover project skills from `.fx/skills` before other workspace and compatibility roots
- **External skill authorities:** Allow symlinked skills under explicitly trusted external directories through `FX_SKILL_SYMLINK_AUTHORITIES`

### Improvements

- **Provider setup:** Activate a catalog-valid model after subscription login, reauthenticate logged-out providers through `/setup`, and show Codex authorization as a clickable terminal link
- **Provider model catalogs:** Show provider-advertised models, context windows, and effort levels in `/model` and the status line
- **Session listings:** Show saved session names, readable UTC timestamps, language names, and singular turn counts while preserving the existing JSON fields
- **Session cache reads:** Keep session listings and latest-session resume responsive while another session defers cache publication
- **Terminal tab titles:** Label interactive tabs with the session or workspace and active model, keep them current across rename, resume, and model changes, and clear them on exit
- **Terminal activity:** Keep each command or shell attached to its terminal activity row through completion, distinguish graceful close from force close, and hide no-op `cd . &&` prefixes
- **Terminal action arguments:** Advertise only the fields relevant to the selected action and limit unsaved `fx ask` sessions to `terminal.exec`
- **Auto mode reads:** Run routine read-only commands and hardened Git inspection directly without automatic review
- **Automatic denial recovery:** Return destructive actions to the agent for replanning and finish repeated no-progress denials as normal assistant output instead of opening a permission prompt
- **One-off subagents:** Keep active one-off subagents visible, deliver one final result, and retire them after completion while leaving persistent subagents reusable
- **Startup preferences:** Show saved reasoning effort and Fast mode immediately while model capabilities load
- **Dev build identity:** Add the commit and `[dev]` marker to dev-channel welcome headers without changing stable release headers
- **MCP reload feedback:** Replace internal health details with concise server availability and recovery guidance
- **Help layout:** Keep command descriptions close to command names on wide terminals
- **Native binary size:** Reduce the macOS arm64 release footprint while preserving existing behavior
- **Stable upgrades:** Restore forward-only version ordering across manual, automatic, and Ctrl+G upgrades

### Bug Fixes

- **Oversized images:** Normalize large macOS image snapshots without changing the originals and reject attachments locally when a bounded snapshot cannot be prepared
- **Corrupt memory stores:** Report malformed, oversized, or unreadable stores and preserve their original bytes instead of overwriting them
- **Non-regular file reads:** Reject FIFOs and other non-regular `read_file` targets before they can block
- **Malformed tool loops:** End a turn after three consecutive malformed-only tool batches and reset recovery after a valid batch
- **Terminal null placeholders:** Treat textual `"null"` values as absent for unused terminal fields while preserving real command text that contains the word
- **Terminal keyboard input:** Ignore unknown completed escape sequences and handle Ghostty kitty Escape reports with Caps Lock, Num Lock, and event suffixes
- **Credential fallback:** Continue to a stored API key when saved `fx login` credentials cannot load or refresh while keeping the login failure available for diagnostics
- **Vision recovery:** Retry replay-safe requests once after a post-Vision assistant-prefill rejection
- **Thinking status:** Keep the Thinking indicator and elapsed timer visible while automatic command review runs
- **Terminal helper compatibility:** Reject unsupported start, signal, and force-close requests from stale terminal helpers without losing unrelated sessions
- **WASM project context:** Skip unavailable local project-instruction probes in browser hosts while preserving host-supplied context
- **Idle terminal traffic:** Stop polling the terminal theme while idle and continue retinting after supported theme notifications

### Security

- **Command approval patterns:** Restrict wildcard command allows to static shell words and keep destructive shell commands and file deletion outside automatic review
- **macOS login storage:** Store native `fx login` sessions in Keychain with verified migration, refresh, restart, and logout behavior
- **MCP configuration writes:** Save `~/.fx/mcp.json` atomically with private permissions, reject linked targets, and preserve the previous configuration when a write fails
- **MCP session retirement:** Keep retired HTTP session IDs alive until in-flight requests drain
- **Provider response limits:** Reject oversized Codex and Grok catalogs, streams, tool data, and replay state while keeping later input usable
- **ACP permission validation:** Validate permission input before writing JSON-RPC frames

## 0.0.4

### New Features

- **Session resume command:** Resume the latest workspace session or an exact session ID with `fx session resume`
- **Headless permission prompts:** Add `--prompt-permissions` so JSON and quiet `fx ask` runs can request Y/N approval on a TTY while keeping stdout clean

### Improvements

- **Auto mode permissions:** Run routine reversible development commands and new-file creation directly, then ask for human approval after repeated automatic review denials
- **Command discovery:** Rank exact, prefix, and substring slash-command matches and highlight the selected help description
- **Terminal attention bells:** Emit one terminal bell when fx pauses for permission or other input so terminal multiplexers can flag waiting panes
- **Transcript scrollback:** Preserve retained transcript rows in native scrollback across pruning, resize, and reflow

### Bug Fixes

- **Session cache contention:** Continue same-workspace session writes and keep listing and resume results current while another process holds the latest-session cache lock
- **Reasoning effort settings:** Change reasoning effort without crashing or replacing the selected model
- **Web redirects:** Follow HTTP 303 redirects in `web_fetch`
- **Command output separation:** End command output that lacks a trailing newline before rendering the next `fx ask` tool header
- **Skill discovery:** Show one entry for skills reached through symlinked compatibility roots while preserving distinct same-name skills
- **libfx session transitions:** Cancel active cooperative turns before starting a fresh session so the terminal remains responsive
- **Memory activity:** Present `memory list` as a read instead of a write
- **Unsupported login shells:** Fall back to zsh on macOS or Bash elsewhere when the configured login shell is unsupported
- **Process cleanup:** Cancel and reap headless terminal commands on SIGTERM, preserve signal status, and tolerate short-lived Linux processes disappearing during cleanup
- **Model output limits:** Omit invalid limits that consume a model's full context window
- **Terminal lease transitions:** Reject write payloads on lease acquisition, release, and revocation before session state changes

## 0.0.3

### Improvements

- **JSON recovery progress:** Report retry, recovery, and safety-pause status on stderr during `fx ask --json` while keeping stdout parseable
- **Notification sounds:** Use clearer 48 kHz AAC cues with full tails and the intended volume differences between actions

### Bug Fixes

- **Memory clearing:** Succeed when memory is already absent, but report real deletion failures instead of claiming memories were cleared
- **Background URLs:** Refuse `/background open` for stopped or stale tasks so saved URLs cannot open an unrelated process after port reuse
- **Model catalogs:** Reject malformed catalog responses with a nonzero exit instead of treating them as an empty model list
- **Skill creation:** Show invalid `/skills create` names inline and keep the current session, transcript, and composer usable
- **GLM 5.2 responses:** Restore responses for fx login sessions without changing requests for other models

## 0.0.2

### New Features

- **Unified terminal execution:** Run captured foreground commands and durable interactive sessions through the `terminal` tool, with the user's shell profile loaded by default and `clean` as an explicit opt-out
- **Saved session permissions:** Store exact allow or deny rules with `/permissions remember`, list them by stable ID, and remove them with `/permissions revoke`
- **MCP server awareness:** Show the agent the configured server aliases, availability, and visible tool counts so it can find and use MCP capabilities

### Improvements

- **Auto mode recovery:** Let the agent revise its plan after denied, timed-out, or invalid reviews and return a tools-disabled response after repeated blocks instead of stalling for approval
- **Trusted auto mode actions:** Allow bounded reads, hardened read-only Git commands, and prepared workspace edits to proceed without extra review while keeping ambiguous or sensitive actions gated
- **MCP connection reliability:** Connect to legacy stdio servers, cancel stalled reloads, and report the required `oauth.issuer` override when issuers do not match
- **MCP failure handling:** Show concise server errors and stop a third matching failed call before it runs
- **Terminal action recovery:** Reject invalid terminal fields before running anything and return one complete correction without repeating the same repair loop
- **Fast mode defaults:** Start new sessions with `zai/glm-5.2` without enabling Fast mode while preserving explicit preferences and `/fast`

### Bug Fixes

- **WebAssembly terminal input:** Keep input responsive during continuous streams, queue follow-up prompts until the active response completes, and preserve the queued prompt text
- **Terminal job cleanup:** Force-close descendant jobs spawned by any Linux thread and return `session_lost` when fx cannot confirm complete cleanup

## 0.0.1

### New Features

- **Current fx documentation:** Route questions about fx through the public documentation index before answering

### Improvements

- **Scoped project instructions:** Continue safe read-only inspections after loading more specific project instructions and defer only affected state-changing tools
- **Light terminal readability:** Improve syntax highlighting and help contrast on light terminal backgrounds while keeping redirected and structured output uncolored
- **Transcript review navigation:** Preserve tail following, scroll bookmarks, and expanded command history when switching between Ctrl+O Review and Full detail
- **Binary size safeguards:** Track native binary growth across every supported platform
- **Release validation reliability:** Harden asynchronous terminal and Gateway readiness checks to prevent false failures

### Bug Fixes

- **Wrapped diff layout:** Keep wrapped file-diff rows aligned with their gutters across Inline, Review, and Full detail
- **Inline picker layout:** Keep the transcript and composer adjacent when closing inline pickers instead of leaving a blank band in the frame
- **Native Node.js fetch lifecycle:** Keep native sessions reusable after early response completion, cancel only the matching host fetch, and reject incompatible addon versions before startup
- **Terminal cleanup:** Allow tmux sessions a bounded settling period after shutdown while retaining strict ownership checks
