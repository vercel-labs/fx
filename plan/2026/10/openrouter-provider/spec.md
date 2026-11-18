# OpenRouter provider: specification

Status: draft, 2026-10-14

## Summary

Add OpenRouter as a built-in fx provider named `openrouter`, alongside `gateway`, `codex`, and `grok`. A user with an OpenRouter API key can select OpenRouter, choose any tool-capable model from OpenRouter's live catalog, and run interactive, `fx ask`, and ACP sessions. Compaction, reasoning, prompt caching, usage, and cost reporting work without any hand-written model metadata.

## Background

### What works today

fx already supports user-defined "custom connections" under `providers` in `~/.fx/settings.json` (`src/core/config/configured_provider.zig`). They use the `openai-chat-completions` protocol (`src/gateway/chat_completions.zig`, `src/gateway/chat_completions_protocol.zig`). With the following profile settings, a basic OpenRouter session with text and tools already runs:

```json
{
  "providers": {
    "router": {
      "protocol": "openai-chat-completions",
      "base_url": "https://openrouter.ai/api/v1",
      "auth": { "type": "bearer", "env": "OPENROUTER_API_KEY" },
      "tool_choice_mode": "send"
    }
  },
  "provider": "router",
  "models": { "router": "anthropic/claude-sonnet-5.5" }
}
```

### Gaps in the custom-connection path

| Area | Current behavior | Evidence |
|---|---|---|
| Model discovery | No `GET /models` call. `/model` lists only the keys in `model_metadata`. | `chat_completions.zig` `fetch_catalog` |
| Context window | Without `context_window`, `usableInputTokens` returns null. Automatic compaction never runs, and fx can only recover after an overflow error. | `compactor/window.zig` |
| Selection UI | The `/provider` picker lists only `gateway`, `codex`, and `grok`. | `provider_catalog.zig`, `app_commands.zig` |
| Reasoning | Setting `reasoning` on a request is rejected, and no effort is sent. | `chat_completions_protocol.zig` `validate_request` |
| Prompt caching | Rejected. `cache_control` is never written, so Anthropic and Gemini models pay full input price on every turn. | same |
| Usage | Only `prompt_tokens`, `completion_tokens`, and `total_tokens` are read. `cost`, `cached_tokens`, and `reasoning_tokens` are dropped. | `chat_completions_protocol.zig` usage parse |
| Stream errors | `finish_reason: "error"` fails as `InvalidFinishReason`. A mid-stream `{"error":...}` becomes a bare `ProviderError` and its message is lost. | `chat_completions_protocol.zig` `Reducer.accept` |
| Trailing usage chunk | OpenRouter sends a final usage chunk that repeats `finish_reason` with an empty delta. The reducer accepts only `role` and `content` after a finish, so extra null fields could fail with `InconsistentFinishReason`. This needs verification against a recorded stream. | same |
| HTTP errors | 402 (out of credits) and 408 fall into the generic `provider_error`. Retry-After is read only as integer seconds. | `chat_completions.zig` `failure_kind`, `model_response_recovery.zig` |
| Attribution | No `HTTP-Referer` or `X-OpenRouter-Title` headers, so fx does not appear in OpenRouter's app rankings. | `chat_completions.zig` `post` |
| Auth | The only credential source is an environment variable. There is no stored key and no `fx login`. | `credentials.zig` |
| Session titles, reviewer | No `title_model`. The auto-mode reviewer needs `tool_choice_mode: "send"` to force its tool call. | `provider_set.zig`, `chat_completions.zig` `review` |
| Connections | A new `std.http.Client` is created for every request. | `chat_completions.zig` `post` |

### Relevant OpenRouter API facts

Sources: openrouter.ai/docs, API reference pages on streaming, errors, models, reasoning tokens, and prompt caching.

- Base URL is `https://openrouter.ai/api/v1`. Auth is `Authorization: Bearer <key>`. The API is OpenAI Chat Completions compatible.
- Optional attribution headers are `HTTP-Referer` and `X-OpenRouter-Title`. `X-Title` is also accepted.
- `GET /api/v1/models` returns `data[]` with `id`, `context_length`, `top_provider.max_completion_tokens`, `supported_parameters` (for example `tools` and `reasoning`), `architecture.input_modalities`, and `pricing`. It accepts a `supported_parameters=tools` filter.
- Streaming sends SSE comment keep-alives such as `: OPENROUTER PROCESSING`. Usage arrives in a final chunk before `[DONE]` that repeats `finish_reason`.
- Once streaming has started, errors arrive with HTTP 200 as a top-level `error` object and `finish_reason: "error"`. Errors before that use normal status codes: 400, 401, 402 (insufficient credits), 403 (moderation), 408, 429, 502 (model down), and 503 (no provider meets the routing constraints).
- `finish_reason` is normalized to `stop`, `length`, `tool_calls`, `content_filter`, or `error`. The raw value is in `native_finish_reason`.
- `reasoning: { effort | max_tokens, exclude, enabled }` controls reasoning. Responses stream `reasoning` text and `reasoning_details[]`. `reasoning_details` must be sent back unmodified on assistant messages so reasoning continues across tool calls.
- Anthropic, Gemini, and Qwen models need explicit `cache_control` breakpoints on content parts. OpenAI, Grok, DeepSeek, and similar models cache automatically. Cache hits and writes appear in `usage.prompt_tokens_details.cached_tokens` and `cache_write_tokens`.
- `usage` includes `cost` in USD credits.
- Request fields specific to OpenRouter include `provider` (routing preferences), `models` (fallback list), and `plugins`.

## Goals

1. `fx provider openrouter`, `--provider openrouter`, `FX_PROVIDER=openrouter`, and the `/provider` picker select OpenRouter.
2. `fx login openrouter` and `/login` sign in through the browser with OpenRouter's OAuth PKCE flow and store the resulting key in the existing secret store. `OPENROUTER_API_KEY` also works, and pasting a key is the fallback when no browser is available.
3. `anthropic/claude-sonnet-5.5` is the default model, so a new user can sign in and start without choosing one.
4. `/model` and `fx models` list OpenRouter's tool-capable models from the live catalog, including context window, output limit, vision, and reasoning support.
5. Automatic compaction uses the catalog's `context_length`.
6. fx's effort setting maps to `reasoning.effort` on models that support it, and `reasoning_details` is replayed.
7. Anthropic and Gemini models receive `cache_control` breakpoints. Cached-token counts reach the usage ledger.
8. Per-turn cost reaches the usage ledger. `/usage` shows the key's credit usage and limit.
9. Stream and HTTP errors produce typed, actionable messages. 402 reports "out of credits" with a link to the OpenRouter credits page.
10. Requests carry fx attribution headers.
11. libfx (napi and wasm) can select `openrouter` with a host-supplied key.

Stream fixes that are not specific to OpenRouter (goal 9 and the usage fields in goal 8) go into the shared chat-completions protocol, so custom connections benefit too.

## Non-goals

- OpenRouter's Responses API or Anthropic Messages API endpoints. This work uses Chat Completions only.
- `plugins` (web search, file parser) and the `models` fallback array.
- Image, audio, or video output models.
- Removing the custom-connection path or migrating existing custom connections automatically.

## Design

### Ownership

| Concern | Owner |
|---|---|
| Provider identity, parsing, reserved id | `src/core/config/model_provider.zig`, `configured_provider.zig` |
| Bundle slot and auth strategy | `src/core/gateway/provider_set.zig`, `src/builtins/providers.zig` |
| Credential source and stored key | `src/core/auth/credentials.zig`, `src/core/shared/types.zig`, `src/core/auth/auth_runtime.zig` |
| Browser sign-in | New `src/core/auth/openrouter_oauth.zig`, reusing `oauth.zig` PKCE helpers and `browser_callback.zig` |
| Picker and status presentation | `src/core/auth/provider_catalog.zig`, `provider_picker_catalog.zig`, `src/core/output/output_contracts.zig` |
| Wire dialect, catalog, reviewer | New `src/gateway/openrouter.zig`, `openrouter_models.zig`, `openrouter_permission_reviewer.zig`. They reuse `chat_completions_protocol.zig`. |
| Shared stream and usage fixes | `src/gateway/chat_completions_protocol.zig`, `chat_completions.zig` |
| `/usage` credits | New `src/usage/openrouter.zig`, plus `usage.zig` scope |
| Commands and help | `src/builtins/commands.zig`, `src/core/cli/cli_surface.zig` |
| libfx | `src/napi_core_main.zig`, `src/wasm_core_main.zig`, `src/gateway/host_*`, `sdk/` |

### Provider identity

- Add `ProviderId.openrouter` with the label `"openrouter"`. Saved sessions write it as a plain string, like the other built-ins.
- Add `"openrouter"` to the reserved ids in `configured_provider.validate_id`, as was done for `grok`. A profile that already defines a custom connection named `openrouter` gets a dedicated error that tells the user to rename it or delete it in favor of the built-in. The error never falls back to a generic parse failure.
- `models.openrouter` in settings stores the selected model, like `models.grok`.

### Authentication

OpenRouter's OAuth flow returns an ordinary user-controlled API key, not an access token. The key has no expiry and there is no refresh step, so after sign-in every source is the same bearer key.

- Credential sources: `CredentialSource.openrouter_api_key` (environment) and `.openrouter_login` (secret store, written by sign-in or by key entry).
- Resolution order: `OPENROUTER_API_KEY`, then the stored key.
- `fx login openrouter` runs the browser flow:
  1. Generate a PKCE verifier and S256 challenge, and a `state` value (`oauth.zig` `randomUrlSafeSecret`, `pkceChallengeAlloc`).
  2. Start the loopback callback server from `browser_callback.zig` on a random localhost port.
  3. Open `https://openrouter.ai/auth?callback_url=http://localhost:<port>/callback&code_challenge=...&code_challenge_method=S256&state=...`, and print the URL as well.
  4. On the callback, check `state`, then `POST https://openrouter.ai/api/v1/auth/keys` with `code`, `code_verifier`, and `code_challenge_method`.
  5. Validate the returned key with `GET /api/v1/key` and store it.
- Headless mode (`fx login openrouter --headless`, also chosen automatically when no browser can be opened, such as over SSH): omit `callback_url`. OpenRouter shows a code, the user pastes it, and fx exchanges it the same way. OpenRouter requires `code_challenge` in this mode. Codes are single use and expire after 10 minutes.
- `fx login openrouter --api-key` reads a pasted key with hidden input, validates it, and stores it.
- `fx logout openrouter` deletes the stored key. fx cannot revoke an OpenRouter key through the API, so logout prints that the key stays active and that it can be deleted in OpenRouter's key settings.
- Keys sent with a localhost callback get a title that OpenRouter derives from the host and port. Setting `key_label=fx` names the key in the user's OpenRouter key list.
- `authorizesCredential` accepts only the OpenRouter sources for `.openrouter`, and the gateway rejects them.
- Keys are redacted from error bodies and debug traces through the existing redaction path.
- The TUI `/login` picker shows OpenRouter with "Sign in with browser" and "Paste API key" options.

### Wire dialect

`openrouter.zig` builds requests with the shared protocol and adds:

- Headers: `HTTP-Referer: https://fx.sh` and `X-OpenRouter-Title: fx`.
- `reasoning: { "effort": <mapped> }` when the catalog lists `reasoning` in `supported_parameters` and fx effort is set. Effort `off` maps to `{ "effort": "none" }` only where the model is not marked mandatory.
- `cache_control: { "type": "ephemeral" }` breakpoints for `anthropic/*`, `google/*`, and `qwen/*` models. Use at most four breakpoints: the last system part, the last tool definition, and the last two user or tool messages. This mirrors the gateway's prompt-caching placement.
- `tool_choice` is always sent, so the reviewer can force its tool.
- `max_tokens` comes from `top_provider.max_completion_tokens`, capped by fx's output budget.
- Optional `provider: { order, allow_fallbacks }`, mapped from the existing `provider_order` and `provider_strict` config (see open question 2).
- A pooled HTTP client is reused across turns in a session.

### Model catalog

- `openrouter_models.zig` fetches `GET /api/v1/models?supported_parameters=tools` with a 1 MiB cap and a 30-second timeout, following `xai_grok_models.zig`.
- It maps each entry to fx `ModelCapabilities`: `context_length` to the context window, `max_completion_tokens` to the output limit, `image` in `input_modalities` to vision, and `reasoning` in `supported_parameters` to reasoning support.
- The catalog is cached on disk under `~/.fx/` with a time-to-live. If a fetch fails, the stale cache is used.
- If the selected model is missing from the catalog, fx falls back to unknown limits and reactive compaction, and warns once.
- The default model is `anthropic/claude-sonnet-5.5`, the newest Sonnet in the catalog as of 2026-10-14. fx pins the id instead of using OpenRouter's `~anthropic/claude-sonnet-latest` alias, so the default changes only in an fx release.
- `title_model` and the reviewer's default model are fixed, low-cost catalog ids (open question 1).

### Shared protocol changes

These changes go into `chat_completions_protocol.zig` and apply to every chat-completions provider:

- Accept `finish_reason: "error"` and map it to a typed provider failure that keeps the `error.message`.
- Keep the message and code of a mid-stream `{"error":...}` object instead of returning a bare `ProviderError`.
- After a finish, accept trailing chunks whose deltas are empty or contain only null fields, and accept a repeated identical `finish_reason`.
- Parse `usage.cost`, `prompt_tokens_details.cached_tokens`, `prompt_tokens_details.cache_write_tokens`, and `completion_tokens_details.reasoning_tokens` into `types.Usage`.
- Classify 402 as `insufficient_credits` and 408 as `timeout`. 408 is retryable.
- Parse Retry-After as either seconds or an HTTP date.

### Usage and credits

- Per-turn cost and cache tokens are written to the durable usage ledger.
- `/usage` gets an `openrouter` scope. It reads `GET /api/v1/key` and shows usage, limit, and remaining credits.

### Output and errors

- `fx status` and the footer show "OpenRouter" and the credential source.
- A missing credential produces: "OpenRouter is not signed in. Run `fx login openrouter` or set OPENROUTER_API_KEY."
- 402 produces: "OpenRouter credits exhausted" with a link to OpenRouter's credits page. Confirm the URL before shipping.
- 503 from routing constraints produces a message that names the routing constraint, if one was set.

### Testing seams

- `FX_E2E_OPENROUTER_BASE_URL` overrides the API base URL, and `FX_E2E_OPENROUTER_AUTH_URL` overrides the browser authorization page, in end-to-end tests. Like the existing `FX_E2E_*` overrides, they are accepted only for loopback URLs.
- The browser opener is injectable, so tests can follow the authorization redirect without a real browser.
- A Bun fake server `tests/e2e/fixtures/openrouter.ts` serves `/auth`, `/auth/keys`, `/models`, `/key`, and `/chat/completions`. It extends `fixtures/chat-completions.ts` with SSE comments, a trailing usage chunk, cost fields, `reasoning_details`, mid-stream errors, and 402 and 503 responses.
- Sanitized recordings of real OpenRouter streams are stored as Zig test fixtures. They come from Anthropic, OpenAI, Gemini, and one open-weights model.

## Acceptance criteria

1. `OPENROUTER_API_KEY=... ./zig-out/bin/fx ask --provider openrouter --model <id> "..."` completes a tool-using turn against real OpenRouter. The process does not abort and stderr is clean.
2. `./zig-out/bin/fx login openrouter` opens the browser, completes sign-in against real OpenRouter, and stores a key that the next session uses. The headless code-paste flow also completes.
3. In the TUI, `/provider` shows OpenRouter. `/model` lists catalog models with context sizes, and selecting one persists `models.openrouter`.
4. A long session on a 128k-context model compacts automatically before overflow.
5. On an Anthropic model, the second turn reports `cached_tokens > 0`.
6. `/usage` shows per-session cost and the key's credit balance.
7. With an empty key balance, the TUI shows the 402 message, the turn ends cleanly, and nothing is retried.
8. Custom connections keep passing `tests/e2e/configured-providers.test.ts` unchanged.
9. `zig build test`, the e2e shards, Shellcheck, Startup Latency, and the macOS arm64 check pass on the PR's exact commit. The `fx help` startup budget does not regress, because catalog fetches happen only after `openrouter` is selected.

## Open questions

1. Title and reviewer models. These need fixed catalog ids that are cheap and reliably tool-capable. The maintainers should choose them, and the choice should be revisited each release.
2. Should the project-level `provider_order` and `provider_strict` (currently the gateway's provider routing) map to OpenRouter's `provider.order` and `allow_fallbacks`, or should OpenRouter get its own keys?
3. Does fx's fast mode map to OpenRouter's `provider.sort: "throughput"`, or is it unavailable on OpenRouter?
