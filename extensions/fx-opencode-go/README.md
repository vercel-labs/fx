# fx-opencode-go

Trusted native extension for OpenCode Go. It uses Zig’s HTTP client, not an embedded JavaScript runtime.
No additional packages are required. The host forwards the selected credential only after request admission.
The executable runs with your OS privileges. An empty environment does not sandbox it or prevent secret retention.

## Build and register

1. From this directory, run `zig build -Doptimize=ReleaseSafe`.
2. Add this entry to `~/.fx/extension.json`, preserving other registrations:

```json
{
  "version": 1,
  "extensions": [{ "path": "/absolute/path/to/fx/extensions/fx-opencode-go" }]
}
```

3. Set `OPENCODE_API_KEY` in the environment used to start fx.
4. Select `opencode-go/deepseek-flash` and reasoning effort `max`.

Only native `yolo` currently authorizes executable activation. `ask` and `auto` remain closed.
Use yolo only when you accept disabling native permission checks for the entire conversation.
Do not enable it merely to bypass an extension approval failure.

## Verified and unverified behavior

Local dogfooding runs the built fx and this executable against a fake-key loopback HTTP peer.
It proves custom endpoints, environment headers, stable `x-opencode-session`, `reasoning_effort: "max"`, native file tools,
empty `reasoning_content` replay, intact large UTF-8 file writes and real terminal streaming.
Real Ctrl+C cancels the HTTP socket; a fresh user request completes without restarting the app.
HTTP errors, redirects, lost finish markers and aggregate tool-budget failures do not replay or disclose secrets.
Header names follow HTTP case rules; duplicate logical bindings fail before executable activation.
Token usage parsing is implemented but has no independent assertion yet. Core rejects stale or oversized events.
HTTP redirects and automatic provider retries are disabled. Provider error bodies do not enter the transcript.
Image input remains disabled until the host supplies verified image snapshots.
The request encoder supports JSON Schema response format, but that path has no local proof yet.

The cached model metadata inherits [DeepSeek V4.1 Flash](https://raw.githubusercontent.com/anomalyco/models.dev/dev/models/deepseek/deepseek-v4.1-flash.toml)
with [Go reasoning and interleaving](https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/models/deepseek-v4.1-flash.toml).
The catalog digest hashes those exact source bytes, separated by a NUL byte.
The public `deepseek-flash` wire alias differs from that metadata ID. Live alias acceptance is unverified.
[models.dev’s provider entry](https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/provider.toml)
notes that the configured Go API and reasoning passthrough are not a public HTTP contract.
Treat local `max` encoding proof as distinct from live maximum-reasoning acceptance.
Live usage requires a real key and may consume plan quota. No live request has been performed.
Four-platform Full CI remains required for the exact feature commit before declaring the work ready.
