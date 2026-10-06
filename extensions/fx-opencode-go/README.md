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
4. Merge these settings into `~/.fx/settings.json`, preserving unrelated settings:

```json
{
  "provider": "extension",
  "models": { "extension": "opencode-go/deepseek-flash" },
  "effort": "max"
}
```

Build fx from the checkout root and run `./zig-out/bin/fx`. Do not use an installed binary to verify this fork.

Use native `ask` for exact executable confirmation without disabling tool permissions. For interactive CLI approval:

```sh
./zig-out/bin/fx ask --prompt-permissions "Say hello"
```

Explicit profile `extension_execute` rules can authorize activation in `ask` or `auto`. Unresolved `auto` activation holds closed.
See [activation policy](../../docs/extensions.md#trust-boundary) before granting a broad executable rule.
Yolo is not required for scoped activation.

## Verified and unverified behavior

Local dogfooding runs the built fx and this executable against a fake-key loopback HTTP peer.
It proves custom endpoints, environment headers, stable `x-opencode-session`, `reasoning_effort: "max"`, native file tools,
empty `reasoning_content` replay, intact large UTF-8 file writes and real terminal streaming.
Real Ctrl+C cancels the HTTP socket; a fresh user request completes without restarting the app.
HTTP errors, redirects, lost finish markers and aggregate tool-budget failures do not replay or disclose secrets.
Header names follow HTTP case rules; duplicate logical bindings fail before executable activation.
Actual saved fx conversations retain the input and output token counts reported by Go. Core rejects stale or oversized events.
HTTP redirects and automatic provider retries are disabled. Provider error bodies do not enter the transcript.
Native image upload forwards only verified snapshot bytes as OpenAI data URLs, never original or snapshot paths.
Local proof retains two PNGs across tool continuation after the original file changes. Live image acceptance remains unverified.
The shipped provider RPC sends strict OpenAI JSON Schema format and completes valid JSON against a local HTTP peer.
This is provider-protocol proof; native CLI does not expose a model response-schema flag. CLI `--json` formats fx output only.

The cached model metadata inherits [DeepSeek V4.1 Flash](https://raw.githubusercontent.com/anomalyco/models.dev/dev/models/deepseek/deepseek-v4.1-flash.toml)
with [Go reasoning and interleaving](https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/models/deepseek-v4.1-flash.toml).
The catalog digest hashes those exact source bytes, separated by a NUL byte.
The public `deepseek-flash` wire alias differs from that metadata ID. Live alias acceptance is unverified.
[models.dev’s provider entry](https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/provider.toml)
notes that the configured Go API and reasoning passthrough are not a public HTTP contract.
Treat local `max` encoding proof as distinct from live maximum-reasoning acceptance.
Live usage requires a real key and may consume plan quota. No live request has been performed.
Four-platform Full CI remains required for the exact feature commit before declaring the work ready.
