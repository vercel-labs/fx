# fx

## 0.0.4

<!-- release:start -->

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

<!-- release:end -->

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
