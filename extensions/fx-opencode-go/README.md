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

## Selected catalog

The cached catalog contains exactly these 13 user-selected Go choices alongside the built-in
Vercel Gateway, Codex and Grok catalogs. Prefix each picker ID with `opencode-go/` in settings.
Chat means Chat Completions; Messages means the Anthropic-compatible Messages API.
Routes follow [Go's endpoint table](https://opencode.ai/docs/go/#endpoints).

| Picker ID | HTTP API | Context / output tokens | Declared efforts | Images | Strict schema |
| --- | --- | --- | --- | --- | --- |
| `deepseek-flash` | Chat | 1,000,000 / 384,000 | low, high, max | Yes | No |
| `glm-5.3` | Chat | 1,000,000 / 131,072 | low, high, max | No | No |
| `glm-5.3-flash` | Chat | 1,000,000 / 131,072 | low, high, max | Yes | No |
| `grok-4.7` | Responses | 500,000 / 500,000 | low, medium, high, xhigh | Yes | Yes |
| `hy4-preview` | Chat | 1,024,000 / 64,000 | none, high | No | No |
| `kimi-k3` | Chat | 1,048,576 / 131,072 | max | Yes | No |
| `longcat-2.5-preview-free` | Chat | 1,000,000 / 131,072 | Provider default | Yes | No |
| `mimo-v2.6-flash` | Chat | 1,048,576 / 131,072 | Provider default | Yes | No |
| `mimo-v2.6-pro` | Chat | 1,048,576 / 131,072 | Provider default | Yes | No |
| `muse-spark-1.3-contributor` | Responses | 1,048,576 / 131,072 | minimal, low, medium, high, xhigh | Yes | Yes |
| `qwen3.8-flash` | Messages | 1,000,000 / 131,072 | low, medium, xhigh | Yes | Yes |
| `qwen3.8-max` | Messages | 1,000,000 / 131,072 | low, medium, xhigh | Yes | Yes |
| `space-bunny` | Chat | 1,048,576 / 524,288 | low, medium, high, xhigh, max | Yes | No |

The stable public alias `opencode-go/deepseek-flash` sends wire ID `deepseek-v4.1-flash`.
There is one DeepSeek picker choice. Every other public ID equals its wire ID.
Models without declared effort omit the wire effort field. Unsupported efforts fail during
preparation, before credential delivery. HY4's none/high and Space Bunny's wider scale come
from Go metadata; their live forwarding remains unverified.

Limits, vision and effort choices are pinned declarations, not live capability guarantees.
The adapter forwards only host-verified image snapshots. Audio, video and PDF modalities
are not projected. Structured output is advertised only for Grok/Muse Responses and Qwen
Messages: their primary documentation explicitly defines strict schemas for the chosen API.
Chat JSON-object mode does not establish strict JSON Schema support. Native CLI `--json`
formats fx output; it does not request a model response schema.

Muse Contributor requires consent to use prompts and completions for model training and an
eligible account/region. Review [Go's privacy terms](https://opencode.ai/docs/go/#privacy)
and [Meta's Contributor terms](https://dev.meta.ai/docs/pricing-rate-limits#contributor-tier) before selecting
it. The adapter does not enable account consent or change provider eligibility.

## Protocol and verification

The adapter freezes each selected wire route before streaming. Chat Completions and Responses
send managed Bearer authentication; Messages sends managed `x-api-key` and
`anthropic-version: 2023-06-01`. Caller headers cannot replace protocol authentication.
HTTPS is required except loopback HTTP for development. Redirects and automatic retries are
disabled; provider error bodies stay out of transcripts.

Each API projects native tools, streamed text, images and complete usage into the same host
contract. Responses preserves encrypted reasoning items; Messages preserves bounded typed
thinking/redacted blocks. New replay carries an API-family tag. Foreign-family replay is
omitted while canonical text and tool history survive model switches. Existing untagged Chat
reasoning remains compatible. Malformed same-family replay or incomplete terminal streams
fail closed before tool execution. Saved sessions retain canonical history, not opaque replay.

Qwen effort and strict schemas share `output_config`. Required `max_tokens` uses the native
request limit or the selected catalog cap; it has no invented fallback. Messages usage uses
final cumulative snapshots. Input includes cache creation/read counts by Messages-compatible
inference; live Go billing semantics remain unverified. Explicit parallel=false projects
`tool_choice.disable_parallel_tool_use`; Go/Qwen enforcement is unverified and the native
host remains authoritative for tool execution policy.

Local dogfooding uses fresh built fx/adapter binaries, fake keys, private profiles and loopback
HTTP peers. It exercises all 13 discoveries and native tool continuations, all directed
API-family saved-session switches, the actual picker, and real terminal conversations for
each API. Streaming fragmentation, cancellation/recovery, snapshot images, strict schema
projection, malformed streams, replay bounds and managed headers have protocol proof.
Paid live capability acceptance has not been tested. Four-platform exact-head Full CI and
the final ship gate remain required before declaring the branch ready.

## Reproducible metadata

The catalog pins [models.dev revision 450aa1d59261b04afd8a6fe6b6dd621272719bc4](https://github.com/anomalyco/models.dev/tree/450aa1d59261b04afd8a6fe6b6dd621272719bc4).
Retrieve provider defaults first, then each selected Go TOML and its referenced base TOML in
the table's order. SHA256 over these 25 exact sources separated by one NUL byte, with no
trailing separator, is `46a4e0fa4499d1266a4957908aed9427715c604e32bc3c709ef4f5906f3a197d`.
Base dictionaries inherit recursively; provider values replace scalars and arrays. Explicit
empty effort arrays stay empty. Missing capability booleans are false. Strict-schema flags
are narrowed to the four primary-proven chosen-API identities above. The catalog file SHA256
is `6c557c12a91d0270a2a0c2872137770a1315a58082b7e52a14e0aa0d37bca415`.

Chosen-API schema and reasoning references:
[Grok reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning),
[Grok schemas](https://docs.x.ai/developers/model-capabilities/text/structured-outputs),
[Muse Responses](https://dev.meta.ai/docs/protocols/responses),
[Muse schemas](https://dev.meta.ai/docs/structured-output),
[Qwen Messages](https://www.alibabacloud.com/help/en/model-studio/anthropic-api-messages).
