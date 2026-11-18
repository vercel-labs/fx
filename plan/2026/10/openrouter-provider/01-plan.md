# OpenRouter provider: implementation plan

Spec: [spec.md](spec.md)

Each milestone is one draft PR, merged in order. Each PR must pass every CI check in AGENTS.md on its exact commit, and must be exercised with `./zig-out/bin/fx` before it is called ready. Milestone 0 has no visible OpenRouter feature on its own, but it fixes custom connections that point at OpenRouter today.

## Milestone 0: Shared chat-completions protocol fixes

Goal: the existing chat-completions path handles OpenRouter's streams, errors, and usage correctly. Label: `type: bug`.

Tasks:

- [ ] Record real OpenRouter SSE streams for an Anthropic, OpenAI, Gemini, and open-weights model, covering text, tool calls, reasoning, a mid-stream error, and a trailing usage chunk. Remove ids and keys, and save them under `src/gateway/testdata/openrouter/`.
- [ ] `chat_completions_protocol.zig`: accept `finish_reason: "error"` and map it to a typed failure that keeps `error.message` and `error.code`.
- [ ] Keep the message from a mid-stream `{"error":...}` object instead of returning a bare `ProviderError`.
- [ ] After a finish, accept trailing chunks with empty or null-only deltas and a repeated identical `finish_reason`. Any other content after the finish is still rejected.
- [ ] Parse `usage.cost`, `prompt_tokens_details.cached_tokens`, `cache_write_tokens`, and `completion_tokens_details.reasoning_tokens` into `types.Usage`.
- [ ] `chat_completions.zig` `failure_kind`: classify 402 as insufficient credits (not retried) and 408 as timeout (retried).
- [ ] `model_response_recovery.zig`: parse Retry-After as either seconds or an HTTP date. Keep the 30-second cap.

Deliverables and tests:

- Zig unit tests in `chat_completions_protocol.zig` that replay every recorded stream through `Reducer`, plus table cases for each new finish and error shape.
- Unit tests for the `failure_kind` mapping and for Retry-After date parsing.
- E2E: extend `tests/e2e/fixtures/chat-completions.ts` with SSE comment lines, a trailing usage chunk, and `finish_reason: "error"`. Add cases to `configured-providers.test.ts`. The file's existing corpus and shard entries stay as they are.
- Manual check: a custom connection to real OpenRouter completes a tool turn in `./zig-out/bin/fx`.

## Milestone 1: Built-in provider with an environment key

Goal: `openrouter` is a selectable built-in provider that uses `OPENROUTER_API_KEY` and defaults to `anthropic/claude-sonnet-5.5`. It reuses the generic chat-completions bundle with a fixed base URL. Label: `type: feature`.

Tasks:

- [ ] `model_provider.zig`: add `ProviderId.openrouter`, including `label`, `parse`, `parse_saved`, and `authorizesCredential`. Update every exhaustive `switch` and every ad-hoc `source != ...` check (`auth_runtime.zig`, `output_contracts.zig`).
- [ ] `configured_provider.zig`: reserve `openrouter`. When a profile already defines it, return a dedicated error that tells the user to rename or delete the custom connection.
- [ ] `provider_set.zig`: add the `openrouter` Bundle slot, `AuthStrategy.openrouter`, and a `select` arm.
- [ ] `types.zig` and `credentials.zig`: add the `openrouter_api_key` (`OPENROUTER_API_KEY`) and `openrouter_login` (secret store) sources, including load, exists, missing-credential messages, and the auth-file mapping. Nothing writes `openrouter_login` until Milestone 2.
- [ ] Default model `anthropic/claude-sonnet-5.5` when `models.openrouter` is unset.
- [ ] `provider_catalog.zig` and `provider_picker_catalog.zig`: add the OpenRouter row, and update the picker rows that are hardcoded by index.
- [ ] `settings_store.zig`: add `models.openrouter` persistence.
- [ ] ACP: add the provider option in `src/acp/sessions.zig` and the missing-credential branches in `server.zig` and `prompt.zig`.
- [ ] `output_contracts.zig`: add the "OpenRouter" label and connected status in text and JSON.
- [ ] `commands.zig`: update `--provider` and `fx provider` usage text.
- [ ] Test seam: `FX_E2E_OPENROUTER_BASE_URL`, accepted only for loopback URLs.

Deliverables and tests:

- Unit tests: provider parse and saved-session round trip, reserved-id error with its rename hint, default model selection, credential precedence (env over stored), and gateway rejecting OpenRouter credentials.
- New fake server `tests/e2e/fixtures/openrouter.ts` serving `/chat/completions`.
- New E2E file `tests/e2e/openrouter.test.ts`: `fx ask` with an env key and the default model, the missing-credential message, a profile with a custom connection named `openrouter`, `fx provider openrouter` persistence, and resuming a saved session.
- Extend `tui-auth-source-selection.test.ts`: OpenRouter appears in the picker and can be selected.
- Extend `acp.test.ts`: selecting the provider and the missing-credential error.
- `scripts/pgso/corpus.json`: classify `openrouter.test.ts` as **Verification-only**, because it covers auth and setup and should not make code hot.
- `tests/e2e/ci-shard-weights.json`: add a weight for the new file.

## Milestone 2: Browser sign-in

Goal: `fx login openrouter` and `/login` sign the user in through the browser with OpenRouter's OAuth PKCE flow. Key entry and a headless code flow cover machines without a browser. Label: `type: feature`.

OpenRouter's flow returns a long-lived API key, not an access token, so there is no refresh or expiry handling. The key is stored as the `openrouter_login` source.

Tasks:

- [ ] `src/core/auth/openrouter_oauth.zig`: build the authorization URL (`callback_url`, S256 `code_challenge`, `state`, `key_label=fx`) with the `oauth.zig` helpers, and exchange the code at `POST /api/v1/auth/keys`.
- [ ] Loopback callback: reuse `browser_callback.zig` on a random localhost port, check `state`, and time out after 10 minutes to match the code lifetime.
- [ ] Headless flow: omit `callback_url`, read the pasted code, and exchange it. Use it for `--headless` and automatically when no browser can be opened.
- [ ] `--api-key`: hidden key entry.
- [ ] Validate every new key with `GET /api/v1/key` before storing it.
- [ ] `fx login openrouter` and `fx logout openrouter` in `cli_surface.zig`. Logout deletes the stored key and says that the key remains active on OpenRouter until it is deleted in OpenRouter's key settings.
- [ ] TUI: add the OpenRouter `/login` picker row with "Sign in with browser" and "Paste API key", and `/logout openrouter`, in `auth_runtime.zig` and `app_auth_runtime.zig`.
- [ ] ACP: tell an ACP client with no OpenRouter credential how to sign in.
- [ ] `commands.zig`: `fx login` and `fx logout` usage text, including `--headless` and `--api-key`.
- [ ] Test seam: `FX_E2E_OPENROUTER_AUTH_URL` (loopback only) and an injectable browser opener.

Deliverables and tests:

- Unit tests: authorization URL contents, `state` mismatch rejected, a reused or expired code reported as a clear error (403 from the exchange), 400 for a mismatched challenge method, and the key never written to traces.
- Fake server: add `/auth`, which redirects to the callback with a code, and `/auth/keys` and `/key` to `fixtures/openrouter.ts`.
- `openrouter.test.ts`: browser sign-in end to end with the fake opener, headless code paste, `--api-key`, logout, and the env key overriding a stored key.
- Extend `tui-auth-source-selection.test.ts`: sign in from the `/login` picker.
- Manual check: `./zig-out/bin/fx login openrouter` against real OpenRouter in a real browser, then a turn with the stored key.

## Milestone 3: Model catalog, request dialect, reviewer, and titles

Goal: OpenRouter works without hand-written metadata, and `/model` shows the live catalog. Label: `type: feature`.

Tasks:

- [ ] `src/gateway/openrouter_models.zig`: fetch `/models?supported_parameters=tools` (1 MiB cap, 30-second timeout) and map entries to `ModelCapabilities` (context window, output limit, vision, reasoning).
- [ ] Cache the catalog on disk under `~/.fx/` with a time-to-live and use the stale copy if a fetch fails. Fetch only when `openrouter` is the active provider, to protect the startup budget.
- [ ] Provide `cli_model_catalog` and `model_catalog`, so `/model` and `fx models` list catalog models with their context size.
- [ ] `src/gateway/openrouter.zig`: wrap the shared protocol. Add the `HTTP-Referer` and `X-OpenRouter-Title` headers, always send `tool_choice`, take `max_tokens` from the catalog, and reuse a pooled HTTP client.
- [ ] When a model is missing from the catalog, warn once and fall back to unknown limits.
- [ ] `src/gateway/openrouter_permission_reviewer.zig`: use a fixed reviewer model (spec open question 1) with a forced tool call.
- [ ] Set `title_model` on the bundle.
- [ ] `src/builtins/providers.zig`: wire the native bundle.
- [ ] Fill the compactor's window from catalog capabilities, so automatic compaction runs.

Deliverables and tests:

- Unit tests: catalog parsing (missing fields, oversized body, non-tool models filtered out), cache time-to-live and stale fallback, header injection, and `max_tokens` capping.
- Fake server: add `/models` to `fixtures/openrouter.ts`.
- `openrouter.test.ts` cases: `/model` lists fake catalog models, automatic compaction triggers below the fake context limit, a generated session title, an auto-mode review that forces its tool call, and attribution headers asserted by the fake server.
- Startup check: run `./benchmarks/startup.sh --quick` locally and confirm `fx help` does not change.
- Reconsider the PGSO classification. If the catalog and stream path now carries common product behavior, move it to **Training**.

## Milestone 4: Reasoning and prompt caching

Goal: reasoning models think and continue their reasoning across tool calls, and Anthropic and Gemini models hit the prompt cache. Label: `type: feature`.

Tasks:

- [ ] Remove the `reasoning` rejection for the OpenRouter dialect only. Map fx effort levels to `reasoning.effort`, gated on the catalog's `reasoning` parameter. Do not send `none` to models that require reasoning.
- [ ] Confirm that `reasoning_details` replay works when the provider identity is `openrouter`. The binding identity currently uses the configured definition.
- [ ] Add `cache_control` breakpoints for `anthropic/*`, `google/*`, and `qwen/*`: the last system part, the last tool, and the last two user or tool messages, with at most four in total.
- [ ] Set `capabilities.gateway_prompt_caching`, or a new OpenRouter-specific flag, so the UI and `/usage` show cache data.

Deliverables and tests:

- Unit tests: effort mapping table, request snapshot with breakpoints for each model family, no breakpoints for automatic-cache families, and a breakpoint count that never exceeds four.
- Replay test using the recorded Anthropic reasoning and tool stream (Milestone 0 fixture), asserting `reasoning_details` are sent back byte for byte.
- `openrouter.test.ts`: the fake server asserts `reasoning` and `cache_control` in request bodies and returns `cached_tokens`. The TUI then shows reasoning output.
- Live eval (credentialed, run on request): add an OpenRouter scenario to `tests/evals/` using `OPENROUTER_API_KEY` that checks cache hits on turn two.

## Milestone 5: Usage, cost, and credits

Goal: users can see what OpenRouter costs them. Label: `type: feature`.

Tasks:

- [ ] Write per-turn `cost`, cached tokens, and reasoning tokens to the durable usage ledger.
- [ ] `src/usage/openrouter.zig` and a `usage.zig` scope: read `GET /api/v1/key` and show usage, limit, and remaining credits. Add text and JSON rendering in `output_contracts.zig` from one snapshot.
- [ ] 402 message with the credits link. 503 message that names the routing constraint, if one was set.
- [ ] Map `provider_order` and `provider_strict` to `provider.order` and `allow_fallbacks`, if spec open question 2 is accepted.

Deliverables and tests:

- Unit tests: ledger accumulation of cost, `/key` parsing, and rendering snapshots in text and JSON.
- `tests/e2e/tui-usage.test.ts`: an OpenRouter scope case driven by the fake `/key`.
- `openrouter.test.ts`: the 402 path ends the turn cleanly with no retry. A 503 shows the routing message.

## Milestone 6: libfx, docs, and release

Goal: SDK parity and user documentation. Label: `type: feature`. Read `sdk/AGENTS.md` before starting this milestone.

Tasks:

- [ ] `napi_core_main.zig` and `wasm_core_main.zig`: accept `openrouter` with a host-supplied key, and add OpenRouter variants to `host_stream_provider` and `host_model_catalog`.
- [ ] `sdk/`: add type definitions, a provider string, an error code for a missing key, and a test under `sdk/tests/`. Update `sdk/README.md`.
- [ ] `CHANGELOG.md`: add the entry in the next release PR, not in this PR.
- [ ] Manual at fx.sh/docs: open a companion PR for a new "OpenRouter" page under configure-fx, and update the custom-connections page to point to it. If the private repository is not accessible, add a `## Docs` section to the PR description instead.
- [ ] `README.md`: change it only if its provider list would otherwise be wrong.

Deliverables and tests:

- SDK tests run in the `Build & Test` SDK job.
- A run of `scripts/detect-macos-need.sh` to confirm whether macOS CI is needed.
- Final ship-gate run on the last PR.

## Follow-ups (not scheduled)

- `models` fallback arrays and `plugins` (web search) through OpenRouter.
- Mapping fast mode to `provider.sort: "throughput"`.

## Risks

| Risk | Mitigation |
|---|---|
| Real stream shapes differ by upstream model (null fields, duplicate finishes). | Record fixtures in Milestone 0 before any feature work. Keep the reducer strict about content after a finish. |
| Catalog fetch slows startup. | Fetch lazily and in the background, cache on disk, and keep `fx help` out of the path. Startup Latency CI enforces this. |
| Adding a `ProviderId` arm misses ad-hoc checks. | Use the touch-point list from the grok commits (`d42c9769`, `dabb6f22`). Search for `grok_subscription` and `.grok =>` to find every site. |
| A user's custom connection is named `openrouter`. | Show a dedicated error with a rename hint. Add a unit test and a release-note line. |
| Users expect logout to revoke the key. | Say on logout that the key stays active, and name where to delete it. |
| Reviewer or title model ids disappear from OpenRouter. | Validate them against the catalog at startup of an OpenRouter session, and fall back to the turn model with one warning. |
