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

## Curated catalog

The cached catalog adds five coding choices alongside the built-in Vercel Gateway, Codex and Grok providers.
All five use Go's documented [Chat Completions endpoint](https://opencode.ai/docs/go/#endpoints).
Models requiring Responses or Anthropic Messages are excluded because this executable implements Chat Completions only.

| fx model ID | Intended role | Context / output tokens | Effort controls | Image metadata |
| --- | --- | --- | --- | --- |
| `opencode-go/deepseek-flash` | General coding | 1,000,000 / 384,000 | low, high, max | Yes |
| `opencode-go/deepseek-v4-pro` | Complex text reasoning | 1,000,000 / 384,000 | high, max | No |
| `opencode-go/kimi-k3` | Long-context repository work | 1,048,576 / 131,072 | max | Yes |
| `opencode-go/glm-5.3-flash` | Efficient coding alternative | 1,000,000 / 131,072 | low, high, max | Yes |
| `opencode-go/mimo-v2.6-flash` | Lower-cost coding alternative | 1,048,576 / 131,072 | Provider default | Yes |

Roles describe the curation, not a performance guarantee. Limits, image support and effort options are source metadata;
live acceptance of each capability remains unverified. MiMo declares no selectable effort, so fx leaves it to the provider.
The adapter projects verified images only; it does not expose source models' audio, video or PDF modalities.
Structured-output metadata is retained where declared; native CLI `--json` still formats fx output rather than setting a response schema.

The existing public ID `opencode-go/deepseek-flash` remains stable for saved settings and sessions.
Its wire ID is `deepseek-v4.1-flash`, matching its versioned metadata and the endpoint table.
Go's [model listing](https://opencode.ai/zen/go/v1/models) advertises both IDs; this mapping does not depend on an undocumented alias equivalence.

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

The catalog pins [models.dev revision 6b324163](https://github.com/anomalyco/models.dev/tree/6b32416340759c52202fef2b0e69cd89adb74bbe/providers/opencode-go).
Each model inherits its declared `base_model` before applying Go overrides. In the table's order, the catalog digest hashes
the base TOML bytes, when present, followed by the Go model TOML bytes, with one NUL byte between sources.
DeepSeek V4 Pro has a self-contained Go entry and contributes only that entry's bytes.
The public Go docs now document its endpoint. Reasoning passthrough is still not documented there as an HTTP field contract;
treat local effort encoding proof as distinct from live acceptance.
Automated native tool-continuation scenarios exercise all five catalog entries and verify model routing, supported effort
encoding, provider-default omission and preservation of built-in model preferences.
Live usage requires a real key and may consume plan quota. Automated proof makes no live completion requests.
Four-platform Full CI remains required for the exact feature commit before declaring the work ready.
