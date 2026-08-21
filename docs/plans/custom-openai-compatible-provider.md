# Plan: Generic OpenAI-Compatible Provider (`custom`)

Status: implementation in progress. Configuration, credentials, buffered chat completions, and basic tool-call response parsing are implemented. Streaming, remote model catalogs, and capability UI polish remain planned.

This plan adds a third provider to fx alongside Gateway (Vercel AI Gateway) and
Codex (ChatGPT subscription). The new provider is called `custom` and speaks any
OpenAI-compatible chat completions endpoint. One implementation covers
OpenRouter, DeepSeek direct, Moonshot/Kimi, Groq, Together, xAI, Mistral, and
future providers without per-provider code paths.

## Goals

- Users can point fx at any OpenAI-compatible endpoint with a base URL, an API
  key environment variable name, and a model ID.
- Streaming, tool calling, and the `/model` picker work through the same
  internal contracts the Gateway and Codex transports already use.
- Missing provider capabilities degrade visibly instead of failing silently.

## Non-goals for v1

- No per-provider quirk tables or special-case adapters beyond the generic
  normalization described here.
- No storing API keys in settings files or project config.
- No support for gateway-only features such as hosted web search, Fast mode, or
  generation cost lookups on custom endpoints.

## Example configuration

Profile settings at `~/.fx/settings.json`:

```json
{
  "provider": "custom",
  "custom_provider": {
    "base_url": "https://openrouter.ai/api/v1",
    "api_key_env": "OPENROUTER_API_KEY"
  },
  "custom_model": "deepseek/deepseek-chat-v3"
}
```

DeepSeek direct would be `https://api.deepseek.com` with
`DEEPSEEK_API_KEY` and model `deepseek-chat`.

## Answers to the collaboration questions

1. Which module owns the behavior? A new transport in
   `src/gateway/openai_compat.zig`, following the precedent of
   `src/gateway/openai_codex.zig`. Config parsing lives in `src/core/config/`,
   credential resolution in `src/core/auth/`, dispatch wiring in
   `src/core/app/`. `src/main.zig` stays untouched.
2. What is the typed contract? A `.custom` variant of `ProviderId` plus a
   validated `CustomProviderConfig` struct. No ad hoc strings cross module
   boundaries.
3. Does it need persistence? Yes. Settings persist `provider`,
   `custom_provider.base_url`, `custom_provider.api_key_env`, and
   `custom_model`. The API key itself is never persisted; it is read from the
   environment at resolution time, optionally cached in Keychain through the
   existing stored-key path.
4. Does it need both text and JSON output? Yes. Provider switching surfaces in
   the CLI, slash commands, and footer pickers must render from the same
   snapshots via `src/core/output/output_contracts.zig`.
5. What docs and tests land with it? README section, command spec help text,
   unit tests beside every changed file, one classified E2E test file, and a
   wire-format translation matrix reviewed in the PR.

## Phase 0: Translation matrix

Before writing transport code, document the field-level mapping between the
Vercel language-model spec that fx internals consume and the OpenAI wire
format. This table goes in the PR description and drives the fixture tests.

### SSE framing

| Vercel spec event | fx internal event | OpenAI-compatible source |
| --- | --- | --- |
| `{"type":"text-start"}` | text start | implicit on first `delta.content` |
| `{"type":"text-delta"}` | text delta | `choices[0].delta.content` |
| `{"type":"text-end"}` | text end | implicit before finish |
| `{"type":"reasoning-start"}` | reasoning start | first reasoning chunk |
| `{"type":"reasoning-delta"}` | reasoning delta | `delta.reasoning` (OpenAI) or `delta.reasoning_content` (DeepSeek) |
| `{"type":"tool-input-start"}` | tool input start | first `delta.tool_calls[n]` for an index |
| `{"type":"tool-input-delta"}` | tool input delta | `delta.tool_calls[n].function.arguments` appended by index |
| `{"type":"tool-call"}` | tool call | assembled when `finish_reason == "tool_calls"` |
| `{"type":"response-metadata"}` | response metadata | `id`, `model`, `created` fields |
| `{"type":"finish"}` | finish | terminal chunk plus `usage` |
| `{"type":"error"}` | error | non-SSE error JSON or mid-stream error object |

OpenAI streams terminate with a literal `data: [DONE]` line. The Vercel spec
does not use a sentinel. The compat framer owns this difference; nothing above
the adapter sees `[DONE]`.

### Request mapping

| fx concept | OpenAI request field |
| --- | --- |
| system prompt | `messages[0].role = "system"` |
| conversation turns | `messages[]` with `user` and `assistant` roles |
| typed tool contracts from `src/core/tooling/tool_specs.zig` | `tools[]` with `function.name`, `description`, `parameters` |
| forced tool choice | `tool_choice` |
| reasoning effort | omitted in v1 unless the endpoint accepts `reasoning_effort` |
| model id | `model` |
| max steps loop | unchanged, owned by the agent runtime |

### Finish reasons

fx's `ProviderFinishReason` (`src/core/shared/types.zig`) already defines
`stop`, `length`, `content_filter`, and `tool_calls`, which matches the OpenAI
vocabulary exactly. Unknown values map to a generic failure with the raw string
preserved in trace logs, never silently dropped.

### Known format hazards

- Reasoning tokens arrive under at least three names: `reasoning`,
  `reasoning_content`, and Vercel-style typed events. The adapter normalizes
  all of them into one internal reasoning delta event.
- Tool call deltas are index-based. Multiple parallel calls interleave by
  index and must be assembled per index before emitting `tool-call`.
- Error bodies differ per provider. OpenRouter wraps errors in its own shape;
  DeepSeek returns OpenAI-style error objects. Parse both into fx's failure
  categories.
- `/models` catalog responses vary widely in metadata completeness. The picker
  must tolerate sparse entries and fall back to manual model entry.

## Phase 1: Contracts

Files: `src/core/config/model_provider.zig`, `src/core/config/config_runtime.zig`,
`src/core/config/settings_store.zig`.

- Add `.custom` to `ProviderId`. Extend `parse`, `label`
  ("Custom OpenAI-compatible"), `authorizesCredential` (custom authorizes only
  its own credential source), and `usesGatewayAuxiliaries` (returns false).
- Define `CustomProviderConfig`:
  - `base_url`: required, HTTPS only. Loopback HTTP is accepted only under the
    same conditions `gatewayBaseUrl()` uses for `FX_GATEWAY_BASE_URL`.
  - `api_key_env`: required, non-empty, valid environment variable name.
  - Rejection rule: no key material accepted anywhere in config values.
- Add `custom_model` as an independent per-provider model slot, mirroring how
  `codex_model` coexists with `model`.
- Settings parse, patch, serialize, and merge for the new keys, with round-trip
  unit tests matching the existing "provider patch keeps independent models"
  tests.

## Phase 2: Credentials

Files: `src/core/auth/credentials.zig`, `src/core/shared/types.zig`.

- Add a credential source variant for the custom key.
- Resolution reads the environment variable named by `api_key_env` at runtime,
  reusing the existing env loading path.
- Extend missing-credential messages to name the configured variable, for
  example "Set OPENROUTER_API_KEY or run fx setup."
- Ensure the permission system sees no change: credentials flow through the
  existing `resolveForProvider` path with the new provider id.

## Phase 3: Transport

New file: `src/gateway/openai_compat.zig`. This is the bulk of the work.

- Non-streaming first: POST `{base_url}/chat/completions` with
  `Authorization: Bearer`, parse the complete JSON response, map to fx's
  completion type including tool calls and usage.
- Streaming second: own SSE framer producing the internal events listed in the
  Phase 0 table. None of `client.zig`'s Vercel-spec parsing is reused.
- Tool calling: emit `tools[]` from typed tool contracts, assemble index-based
  `tool_calls` deltas, return them through the same invocation path other
  providers use so permissions and presentation are unchanged.
- Usage: parse `usage` from the final chunk. There is no generation endpoint,
  so token counts come from the stream and cost display degrades gracefully.
- Capability degradation rules:
  - No generation endpoint means chunk-based usage only.
  - No hosted web search means the gateway web search tool is unavailable and
    the UI says so rather than sending dead requests.
  - Fast mode is hidden for custom providers.
  - Unknown finish reasons map to a generic failure with tracing preserved.
- Model catalog: GET `{base_url}/models` for the picker, tolerating sparse
  metadata, with manual model entry as fallback.

## Phase 4: Wiring

Files: `src/core/cli/cli_surface.zig`, `src/core/slash_commands/command_specs.zig`,
`src/core/app/app_agent_runtime.zig`, `src/core/app/app_auth_runtime.zig`,
`src/ui/footer/picker_presentation.zig`, `src/ui/footer/model_menu_presentation.zig`.

- `fx provider <gateway|codex|custom>` validates config and credential before
  switching, mirroring the Codex flow including automatic login where sensible.
  For custom there is no OAuth, so validation means config present plus env key
  readable.
- Slash command specs and help text gain the third option.
- Agent runtime routes to the compat transport when the active provider is
  custom.
- Footer and model menu presentations list the third provider and hide
  gateway-only affordances such as Fast mode.

## Phase 5: Docs and tests

Docs:

- README "Bring your own provider" section with OpenRouter and DeepSeek
  examples.
- Command spec help updates.
- CONTRIBUTING needs no change since no new collaboration rules apply.

Tests:

- Unit tests beside every changed file: provider parsing, settings round-trip,
  credential resolution, request serialization, SSE parsing, tool call
  assembly, finish reason mapping, error body parsing.
- Recorded fixtures from at least two real endpoints, OpenRouter and DeepSeek
  direct, because they genuinely differ. Fixtures replay deterministically
  through the parser, in the spirit of the FX_RECORD tape approach.
- New E2E file `tests/e2e/custom-provider.test.ts` driving a local mock server
  over loopback. The mock emits realistic OpenAI quirks: index-based tool call
  deltas, `[DONE]` sentinel, DeepSeek-style reasoning fields, wrapped errors.
  Classify the file in `scripts/pgso/corpus.json` as verification-only because
  it covers correctness of an alternate transport rather than hot product
  behavior.

Verification workflow per CONTRIBUTING:

1. `zig fmt src/` clean.
2. Focused tests for each changed path pass locally.
3. `zig build` succeeds.
4. Exercise the change end to end with `./zig-out/bin/fx` against real
   OpenRouter and DeepSeek endpoints, including a tool-calling turn.
5. Push the feature branch, open a draft PR, and require Full CI plus the ship
   gate on the exact commit before marking ready.

## Risks and mitigations

- Tool call fidelity varies across providers and models. Mitigate with recorded
  fixtures, document known-good models, and never normalize silently.
- Streaming edge cases around reasoning fields and usage chunks. Mitigate by
  shipping non-streaming first and adding streaming behind fixtures.
- Security: the base URL carries the bearer token, so HTTPS is enforced outside
  loopback exactly like `gatewayBaseUrl()` does today.
- Scope creep into per-provider special cases. Any provider needing bespoke
  handling becomes a follow-up with its own contract decision.

## Suggested review sequence

1. Phase 0 matrix posted in the PR description.
2. Phases 1 and 2 as the first reviewable commit: contracts and credentials
   with no behavior change.
3. Phase 3 non-streaming, then streaming, as separate commits.
4. Phase 4 wiring, then Phase 5 docs and E2E.
